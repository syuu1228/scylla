/*
 * Copyright (C) 2015 ScyllaDB
 */

/*
 * This file is part of Scylla.
 *
 * Scylla is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Scylla is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Scylla.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <boost/range/algorithm/transform.hpp>
#include <iterator>
#include <seastar/core/thread.hh>
#include <seastar/util/defer.hh>
#include <sstables/sstables.hh>
#include <seastar/core/do_with.hh>
#include "cql_test_env.hh"
#include "cql3/query_processor.hh"
#include "cql3/query_options.hh"
#include "cql3/statements/batch_statement.hh"
#include <seastar/core/distributed.hh>
#include <seastar/core/shared_ptr.hh>
#include "utils/UUID_gen.hh"
#include "service/migration_manager.hh"
#include "sstables/compaction_manager.hh"
#include "message/messaging_service.hh"
#include "service/storage_service.hh"
#include "auth/service.hh"
#include "db/config.hh"
#include "db/batchlog_manager.hh"
#include "schema_builder.hh"
#include "tmpdir.hh"
#include "db/query_context.hh"
#include "test_services.hh"
#include "db/view/view_builder.hh"
#include "db/view/node_view_update_backlog.hh"
#include "distributed_loader.hh"

// TODO: remove (#293)
#include "message/messaging_service.hh"
#include "gms/gossiper.hh"
#include "gms/feature_service.hh"
#include "service/storage_service.hh"
#include "auth/service.hh"
#include "db/system_keyspace.hh"
#include "db/system_distributed_keyspace.hh"

using namespace std::chrono_literals;

cql_test_config::cql_test_config()
    : cql_test_config(make_shared<db::config>())
{}

cql_test_config::cql_test_config(shared_ptr<db::config> cfg)
    : db_config(cfg)
{
    // This causes huge amounts of commitlog writes to allocate space on disk,
    // which all get thrown away when the test is done. This can cause timeouts
    // if /tmp is not tmpfs.
    db_config->commitlog_use_o_dsync.set(false);
}

cql_test_config::cql_test_config(const cql_test_config&) = default;
cql_test_config::~cql_test_config() = default;

namespace sstables {

future<> await_background_jobs_on_all_shards();

}

static const sstring testing_superuser = "tester";

static future<> tst_init_ms_fd_gossiper(sharded<gms::feature_service>& features, db::config& cfg, db::seed_provider_type seed_provider, sstring cluster_name = "Test Cluster") {
        // Init gossiper
        std::set<gms::inet_address> seeds;
        if (seed_provider.parameters.count("seeds") > 0) {
            size_t begin = 0;
            size_t next = 0;
            sstring seeds_str = seed_provider.parameters.find("seeds")->second;
            while (begin < seeds_str.length() && begin != (next=seeds_str.find(",",begin))) {
                seeds.emplace(gms::inet_address(seeds_str.substr(begin,next-begin)));
                begin = next+1;
            }
        }
        if (seeds.empty()) {
            seeds.emplace(gms::inet_address("127.0.0.1"));
        }
        return gms::get_gossiper().start(std::ref(features), std::ref(cfg)).then([seeds, cluster_name] {
            auto& gossiper = gms::get_local_gossiper();
            gossiper.set_seeds(seeds);
            gossiper.set_cluster_name(cluster_name);
        });
}
// END TODO

class single_node_cql_env : public cql_test_env {
public:
    static const char* ks_name;
    static std::atomic<bool> active;
private:
    shared_ptr<sharded<gms::feature_service>> _feature_service;
    ::shared_ptr<distributed<database>> _db;
    ::shared_ptr<sharded<auth::service>> _auth_service;
    ::shared_ptr<sharded<db::view::view_builder>> _view_builder;
    ::shared_ptr<sharded<db::view::view_update_generator>> _view_update_generator;
private:
    struct core_local_state {
        service::client_state client_state;

        core_local_state(auth::service& auth_service)
            : client_state(service::client_state::for_external_calls(auth_service))
        {
            client_state.set_login(::make_shared<auth::authenticated_user>(testing_superuser));
        }

        future<> stop() {
            return make_ready_future<>();
        }
    };
    distributed<core_local_state> _core_local;
private:
    auto make_query_state() {
        if (_db->local().has_keyspace(ks_name)) {
            _core_local.local().client_state.set_keyspace(_db->local(), ks_name);
        }
        return ::make_shared<service::query_state>(_core_local.local().client_state);
    }
public:
    single_node_cql_env(
            shared_ptr<sharded<gms::feature_service>> feature_service,
            ::shared_ptr<distributed<database>> db,
            ::shared_ptr<sharded<auth::service>> auth_service,
            ::shared_ptr<sharded<db::view::view_builder>> view_builder,
            ::shared_ptr<sharded<db::view::view_update_generator>> view_update_generator)
            : _feature_service(std::move(feature_service))
            , _db(db)
            , _auth_service(std::move(auth_service))
            , _view_builder(std::move(view_builder))
            , _view_update_generator(std::move(view_update_generator))
    { }

    virtual future<::shared_ptr<cql_transport::messages::result_message>> execute_cql(const sstring& text) override {
        auto qs = make_query_state();
        return local_qp().process(text, *qs, cql3::query_options::DEFAULT).finally([qs, this] {
            _core_local.local().client_state.merge(qs->get_client_state());
        });
    }

    virtual future<::shared_ptr<cql_transport::messages::result_message>> execute_cql(
        const sstring& text,
        std::unique_ptr<cql3::query_options> qo) override
    {
        auto qs = make_query_state();
        auto& lqo = *qo;
        return local_qp().process(text, *qs, lqo).finally([qs, qo = std::move(qo), this] {
            _core_local.local().client_state.merge(qs->get_client_state());
        });
    }

    virtual future<cql3::prepared_cache_key_type> prepare(sstring query) override {
        return qp().invoke_on_all([query, this] (auto& local_qp) {
            auto qs = this->make_query_state();
            return local_qp.prepare(query, *qs).finally([qs] {}).discard_result();
        }).then([query, this] {
            return local_qp().compute_id(query, ks_name);
        });
    }

    virtual future<::shared_ptr<cql_transport::messages::result_message>> execute_prepared(
        cql3::prepared_cache_key_type id,
        std::vector<cql3::raw_value> values,
        db::consistency_level cl) override
    {
        auto prepared = local_qp().get_prepared(id);
        if (!prepared) {
            throw not_prepared_exception(id);
        }
        auto stmt = prepared->statement;
        assert(stmt->get_bound_terms() == values.size());

        auto options = ::make_shared<cql3::query_options>(cl, infinite_timeout_config, std::move(values));
        options->prepare(prepared->bound_names);

        auto qs = make_query_state();
        return local_qp().process_statement_prepared(std::move(prepared), std::move(id), *qs, *options, true)
            .finally([options, qs, this] {
                _core_local.local().client_state.merge(qs->get_client_state());
            });
    }

    virtual future<> create_table(std::function<schema(const sstring&)> schema_maker) override {
        auto id = utils::UUID_gen::get_time_UUID();
        schema_builder builder(make_lw_shared(schema_maker(ks_name)));
        builder.set_uuid(id);
        auto s = builder.build(schema_builder::compact_storage::no);
        return service::get_local_migration_manager().announce_new_column_family(s, true);
    }

    virtual future<> require_keyspace_exists(const sstring& ks_name) override {
        auto& db = _db->local();
        assert(db.has_keyspace(ks_name));
        return make_ready_future<>();
    }

    virtual future<> require_table_exists(const sstring& ks_name, const sstring& table_name) override {
        auto& db = _db->local();
        assert(db.has_schema(ks_name, table_name));
        return make_ready_future<>();
    }

    virtual future<> require_column_has_value(const sstring& table_name,
                                      std::vector<data_value> pk,
                                      std::vector<data_value> ck,
                                      const sstring& column_name,
                                      data_value expected) override {
        auto& db = _db->local();
        auto& cf = db.find_column_family(ks_name, table_name);
        auto schema = cf.schema();
        auto pkey = partition_key::from_deeply_exploded(*schema, pk);
        auto ckey = clustering_key::from_deeply_exploded(*schema, ck);
        auto exp = expected.type()->decompose(expected);
        auto dk = dht::global_partitioner().decorate_key(*schema, pkey);
        auto shard = db.shard_of(dk._token);
        return _db->invoke_on(shard, [pkey = std::move(pkey),
                                      ckey = std::move(ckey),
                                      ks_name = std::move(ks_name),
                                      column_name = std::move(column_name),
                                      exp = std::move(exp),
                                      table_name = std::move(table_name)] (database& db) mutable {
          auto& cf = db.find_column_family(ks_name, table_name);
          auto schema = cf.schema();
          return cf.find_partition_slow(schema, pkey)
                  .then([schema, ckey, column_name, exp] (column_family::const_mutation_partition_ptr p) {
            assert(p != nullptr);
            auto row = p->find_row(*schema, ckey);
            assert(row != nullptr);
            auto col_def = schema->get_column_definition(utf8_type->decompose(column_name));
            assert(col_def != nullptr);
            const atomic_cell_or_collection* cell = row->find_cell(col_def->id);
            if (!cell) {
                assert(((void)"column not set", 0));
            }
            bytes actual;
            if (!col_def->type->is_multi_cell()) {
                auto c = cell->as_atomic_cell(*col_def);
                assert(c.is_live());
                actual = c.value().linearize();
            } else {
                auto c = cell->as_collection_mutation();
                auto type = dynamic_pointer_cast<const collection_type_impl>(col_def->type);
                actual = type->to_value(c, cql_serialization_format::internal());
            }
            assert(col_def->type->equal(actual, exp));
          });
        });
    }

    virtual service::client_state& local_client_state() override {
        return _core_local.local().client_state;
    }

    virtual database& local_db() override {
        return _db->local();
    }

    cql3::query_processor& local_qp() override {
        return cql3::get_local_query_processor();
    }

    distributed<database>& db() override {
        return *_db;
    }

    distributed<cql3::query_processor>& qp() override {
        return cql3::get_query_processor();
    }

    auth::service& local_auth_service() override {
        return _auth_service->local();
    }

    virtual db::view::view_builder& local_view_builder() override {
        return _view_builder->local();
    }

    virtual db::view::view_update_generator& local_view_update_generator() override {
        return _view_update_generator->local();
    }

    future<> start() {
        return _core_local.start(std::ref(*_auth_service));
    }

    future<> stop() {
        return _core_local.stop();
    }

    future<> create_keyspace(sstring name) {
        auto query = format("create keyspace {} with replication = {{ 'class' : 'org.apache.cassandra.locator.SimpleStrategy', 'replication_factor' : 1 }};", name);
        return execute_cql(query).discard_result();
    }

    static future<> do_with(std::function<future<>(cql_test_env&)> func, cql_test_config cfg_in) {
        using namespace std::filesystem;

        return seastar::async([cfg_in = std::move(cfg_in), func] {
            logalloc::prime_segment_pool(memory::stats().total_memory(), memory::min_free_memory()).get();
            bool old_active = false;
            if (!active.compare_exchange_strong(old_active, true)) {
                throw std::runtime_error("Starting more than one cql_test_env at a time not supported due to singletons.");
            }
            auto deactivate = defer([] {
                bool old_active = true;
                auto success = active.compare_exchange_strong(old_active, false);
                assert(success);
            });

            utils::fb_utilities::set_broadcast_address(gms::inet_address("localhost"));
            utils::fb_utilities::set_broadcast_rpc_address(gms::inet_address("localhost"));
            locator::i_endpoint_snitch::create_snitch("SimpleSnitch").get();
            auto stop_snitch = defer([] { locator::i_endpoint_snitch::stop_snitch().get(); });

            auto wait_for_background_jobs = defer([] { sstables::await_background_jobs_on_all_shards().get(); });

            auto db = ::make_shared<distributed<database>>();
            auto cfg = cfg_in.db_config;
            tmpdir data_dir;
            auto data_dir_path = data_dir.path().string();
            if (!cfg->data_file_directories.is_set()) {
                cfg->data_file_directories.set({data_dir_path});
            } else {
                data_dir_path = cfg->data_file_directories()[0];
            }
            cfg->commitlog_directory.set(data_dir_path + "/commitlog.dir");
            cfg->hints_directory.set(data_dir_path + "/hints.dir");
            cfg->view_hints_directory.set(data_dir_path + "/view_hints.dir");
            cfg->num_tokens.set(256);
            cfg->ring_delay_ms.set(500);
            cfg->experimental.set(true);
            cfg->shutdown_announce_in_ms.set(0);
            cfg->broadcast_to_all_shards().get();
            create_directories((data_dir_path + "/system").c_str());
            create_directories(cfg->commitlog_directory().c_str());
            create_directories(cfg->hints_directory().c_str());
            create_directories(cfg->view_hints_directory().c_str());
            for (unsigned i = 0; i < smp::count; ++i) {
                create_directories((cfg->hints_directory() + "/" + std::to_string(i)).c_str());
                create_directories((cfg->view_hints_directory() + "/" + std::to_string(i)).c_str());
            }

            set_abort_on_internal_error(true);
            const gms::inet_address listen("127.0.0.1");
            auto& ms = netw::get_messaging_service();
            // don't start listening so tests can be run in parallel
            ms.start(listen, std::move(7000), false).get();
            auto stop_ms = defer([&ms] { ms.stop().get(); });

            auto auth_service = ::make_shared<sharded<auth::service>>();
            auto sys_dist_ks = seastar::sharded<db::system_distributed_keyspace>();
            auto stop_sys_dist_ks = defer([&sys_dist_ks] { sys_dist_ks.stop().get(); });

            auto feature_service = make_shared<sharded<gms::feature_service>>();
            feature_service->start().get();
            auto stop_feature_service = defer([&] { feature_service->stop().get(); });

            // FIXME: split
            tst_init_ms_fd_gossiper(*feature_service, *cfg, db::config::seed_provider_type()).get();

            distributed<service::storage_proxy>& proxy = service::get_storage_proxy();
            distributed<service::migration_manager>& mm = service::get_migration_manager();
            distributed<db::batchlog_manager>& bm = db::get_batchlog_manager();

            auto view_update_generator = ::make_shared<seastar::sharded<db::view::view_update_generator>>();

            auto& ss = service::get_storage_service();
            ss.start(std::ref(*db), std::ref(gms::get_gossiper()), std::ref(*auth_service), std::ref(sys_dist_ks), std::ref(*view_update_generator), std::ref(*feature_service), true, cfg_in.disabled_features).get();
            auto stop_storage_service = defer([&ss] { ss.stop().get(); });

            database_config dbcfg;
            dbcfg.available_memory = memory::stats().total_memory();
            db->start(std::ref(*cfg), dbcfg).get();
            auto stop_db = defer([db] {
                db->stop().get();
            });

            db->invoke_on_all([] (database& db) {
                db.get_compaction_manager().start();
            }).get();

            auto stop_ms_fd_gossiper = defer([] {
                gms::get_gossiper().stop().get();
            });

            ss.invoke_on_all([] (auto&& ss) {
                ss.enable_all_features();
            }).get();

            service::storage_proxy::config spcfg;
            spcfg.available_memory = memory::stats().total_memory();
            db::view::node_update_backlog b(smp::count, 10ms);
            proxy.start(std::ref(*db), spcfg, std::ref(b)).get();
            auto stop_proxy = defer([&proxy] { proxy.stop().get(); });

            mm.start().get();
            auto stop_mm = defer([&mm] { mm.stop().get(); });

            auto& qp = cql3::get_query_processor();
            cql3::query_processor::memory_config qp_mcfg = {memory::stats().total_memory() / 256, memory::stats().total_memory() / 2560};
            qp.start(std::ref(proxy), std::ref(*db), qp_mcfg).get();
            auto stop_qp = defer([&qp] { qp.stop().get(); });

            db::batchlog_manager_config bmcfg;
            bmcfg.replay_rate = 100000000;
            bmcfg.write_request_timeout = 2s;
            bm.start(std::ref(qp), bmcfg).get();
            auto stop_bm = defer([&bm] { bm.stop().get(); });

            view_update_generator->start(std::ref(*db), std::ref(proxy));
            view_update_generator->invoke_on_all(&db::view::view_update_generator::start);
            auto stop_view_update_generator = defer([view_update_generator] {
                view_update_generator->stop().get();
            });

            distributed_loader::init_system_keyspace(*db).get();

            auto& ks = db->local().find_keyspace(db::system_keyspace::NAME);
            parallel_for_each(ks.metadata()->cf_meta_data(), [&ks] (auto& pair) {
                auto cfm = pair.second;
                return ks.make_directory_for_column_family(cfm->cf_name(), cfm->id());
            }).get();
            distributed_loader::init_non_system_keyspaces(*db, proxy).get();
            // In main.cc we call db::system_keyspace::setup which calls
            // minimal_setup and init_local_cache
            db::system_keyspace::minimal_setup(*db, qp);
            auto stop_system_keyspace = defer([] { db::qctx = {}; });
            auto stop_database_d = defer([db] {
                stop_database(*db).get();
            });

            db::system_keyspace::init_local_cache().get();
            auto stop_local_cache = defer([] { db::system_keyspace::deinit_local_cache().get(); });

            db::system_keyspace::migrate_truncation_records().get();

            service::get_local_storage_service().init_messaging_service_part().get();
            service::get_local_storage_service().init_server_without_the_messaging_service_part(service::bind_messaging_port(false)).get();
            auto deinit_storage_service_server = defer([auth_service] {
                gms::stop_gossiping().get();
                auth_service->stop().get();
            });

            auto view_builder = ::make_shared<seastar::sharded<db::view::view_builder>>();
            view_builder->start(std::ref(*db), std::ref(sys_dist_ks), std::ref(mm)).get();
            view_builder->invoke_on_all(&db::view::view_builder::start).get();
            auto stop_view_builder = defer([view_builder] {
                view_builder->stop().get();
            });

            // Create the testing user.
            try {
                auth::role_config config;
                config.is_superuser = true;
                config.can_login = true;

                auth::create_role(
                        auth_service->local(),
                        testing_superuser,
                        config,
                        auth::authentication_options()).get0();
            } catch (const auth::role_already_exists&) {
                // The default user may already exist if this `cql_test_env` is starting with previously populated data.
            }

            single_node_cql_env env(feature_service, db, auth_service, view_builder, view_update_generator);
            env.start().get();
            auto stop_env = defer([&env] { env.stop().get(); });

            if (!env.local_db().has_keyspace(ks_name)) {
                env.create_keyspace(ks_name).get();
            }

            func(env).get();
        });
    }

    future<::shared_ptr<cql_transport::messages::result_message>> execute_batch(
        const std::vector<sstring_view>& queries, std::unique_ptr<cql3::query_options> qo) override {
        using cql3::statements::batch_statement;
        using cql3::statements::modification_statement;
        std::vector<batch_statement::single_statement> modifications;
        boost::transform(queries, back_inserter(modifications), [this](const auto& query) {
            auto stmt = local_qp().get_statement(query, _core_local.local().client_state);
            if (!dynamic_cast<modification_statement*>(stmt->statement.get())) {
                throw exceptions::invalid_request_exception(
                    "Invalid statement in batch: only UPDATE, INSERT and DELETE statements are allowed.");
            }
            return batch_statement::single_statement(static_pointer_cast<modification_statement>(stmt->statement));
        });
        auto batch = ::make_shared<batch_statement>(
            batch_statement::type::UNLOGGED,
            std::move(modifications),
            cql3::attributes::none(),
            local_qp().get_cql_stats());
        auto qs = make_query_state();
        auto& lqo = *qo;
        return local_qp().process_batch(batch, *qs, lqo, {}).finally([qs, batch, qo = std::move(qo), this] {
            _core_local.local().client_state.merge(qs->get_client_state());
        });
    }
};

const char* single_node_cql_env::ks_name = "ks";
std::atomic<bool> single_node_cql_env::active = { false };

future<> do_with_cql_env(std::function<future<>(cql_test_env&)> func, cql_test_config cfg_in) {
    return single_node_cql_env::do_with(func, std::move(cfg_in));
}

future<> do_with_cql_env_thread(std::function<void(cql_test_env&)> func, cql_test_config cfg_in) {
    return single_node_cql_env::do_with([func = std::move(func)] (auto& e) {
        return seastar::async([func = std::move(func), &e] {
            return func(e);
        });
    }, std::move(cfg_in));
}
