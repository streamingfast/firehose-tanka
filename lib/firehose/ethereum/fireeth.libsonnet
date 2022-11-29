local k = import 'sf/k8s.libsonnet';  // some constructor overrides over grafana's "kausal"

//// Reference documentation to find the right thing to call https://jsonnet-libs.github.io/k8s-libsonnet/1.20
local configMap = k.core.v1.configMap;
local deployment = k.apps.v1.deployment;
local sts = k.apps.v1.statefulSet;
local container = k.core.v1.container;
local pvc = k.core.v1.persistentVolumeClaim;
local volumeMount = k.core.v1.volumeMount;
local port = k.core.v1.containerPort;
local service = k.core.v1.service;
local servicePort = k.core.v1.servicePort;
local ingress = k.networking.v1.ingress;
local backendConfig = k.core.v1.backendConfig;
local serviceAccount = k.core.v1.serviceAccount;
local GiB = (1024 * 1024 * 1024);

(import 'config.libsonnet') + {
  fireeth: {
    local c = $._config,
    local images = $._images,

    backup: if c.backup != null then self.newBackup(images.backup, c.backup),
    firehose: if c.firehose != null then self.newFirehose(images.firehose, c.firehose),
    substreams_tier1: if c.substreams_tier1 != null then self.newSubstreamsTier1(images.substreams, c.substreams_tier1),
    substreams_tier2: if c.substreams_tier2 != null then self.newSubstreamsTier2(images.substreams, c.substreams_tier2),
    merger: if c.merger != null then self.newMerger(images.merger, c.merger),
    reader: if c.reader != null then self.newReader(images.reader, c.reader),
    miner: if c.miner != null then self.newMiner(images.miner, c.miner),
    relayer: if c.relayer != null then self.newRelayer(images.relayer, c.relayer),
    combined_index_builder: if c.combined_index_builder != null then self.newCombinedIndexBuilder(images.combined_index_builder, c.combined_index_builder),
    evm_executor: if c.evm_executor != null then self.newEvmExecutor(images.evm_executor, c.evm_executor),

    newFirehose(image, config):: {
      local substreams_rpc_endpoints = if std.isArray(v=config.substreams_rpc_endpoints) then config.substreams_rpc_endpoints else [config.substreams_rpc_endpoints],

      deployment:
        deployment.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          containers=[
            container.new('firehose', image) +
            container.withImagePullPolicy(std.get(config, 'image_pull_policy', 'IfNotPresent')) +
            container.withPorts(
              std.prune([
                port.new('grpc', config.default_grpc_port),
                if config.with_grpc_health_port then port.new('grpc-health', 9001),
                port.new('prom-metrics', 9102),
              ])
            ) +
            container.withCommand(
              std.prune([
                '/app/fireeth',
                'start',
                'firehose',
                '--config-file=',
                '--log-format=stackdriver',
                '--log-to-file=false',
                if config.common_auth_plugin != '' then '--common-auth-plugin=%s' % config.common_auth_plugin,
                '--common-live-blocks-addr=%s' % config.relayer_address,
                '--common-system-shutdown-signal-delay=%s' % config.common_system_shutdown_signal_delay,
                '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
                '--common-first-streamable-block=%s' % config.first_streamable_block,
                '--common-one-block-store-url=%s' % config.one_blocks_url,
                '--common-forked-blocks-store-url=%s' % config.forked_blocks_url,
                '--common-index-store-url=%s' % config.block_index_url,
                '--firehose-grpc-listen-addr=:%d*' % config.default_grpc_port,
              ]) +
              (if config.discoveryServiceURL != '' then [
                 '--firehose-discovery-service-url=%s' % config.discoveryServiceURL,
               ] else []) +
              (
                if !config.substreams_enabled then [] else
                  [
                    '--substreams-client-endpoint=%s' % config.substreams_client_endpoint,
                    '--substreams-client-insecure=%s' % config.substreams_client_insecure,
                    '--substreams-client-plaintext=%s' % config.substreams_client_plaintext,
                    '--substreams-enabled=%s' % config.substreams_enabled,
                    '--substreams-output-cache-save-interval=%s' % config.substreams_output_cache_save_interval,
                    '--substreams-partial-mode-enabled=%s' % config.substreams_partial_mode_enabled,
                    '--substreams-rpc-cache-store-url=%s' % config.substreams_rpc_cache_store_url,
                    '--substreams-rpc-cache-chunk-size=1000',
                  ] +
                  ['--substreams-rpc-endpoints=%s' % a for a in substreams_rpc_endpoints] +
                  [
                    '--substreams-state-store-url=%s' % config.substreams_state_store_url,
                    '--substreams-stores-save-interval=%s' % config.substreams_stores_save_interval,
                    '--substreams-sub-request-block-range-size=%s' % config.substreams_sub_request_block_range_size,
                    '--substreams-sub-request-parallel-jobs=%s' % config.substreams_sub_request_parallel_jobs,
                  ] +
                  if !config.substreams_request_stats_enabled then [] else ['--substreams-request-stats-enabled']

              )
            ) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources) +
            container.withHealthzReadiness(config.default_grpc_port, ssl=true),
          ],
        ) +
        k.util.deployServiceAccount(config.service_account) +
        k.util.runOnNodePoolAndZoneOnlyIfSet(
          std.get(config, 'zone'),
          std.get(config, 'node_pool')
        ),

      publicService:
        k.util.publicServiceFor(self.deployment, grpc_portnames=[std.get(config, 'grpc_portnames', 'firehose-grpc')], backendConfig=config.backend_config_name),

      backendConfig:
        backendConfig.new(
          service=config.backend_config_name,
          healthCheck=backendConfig.healthCheckHttps(port=config.default_grpc_port, requestPath='/healthz'),
          mixin=backendConfig.mixin.spec.withTimeoutSec(86400),
        ),
    },

    newSubstreamsTier1(image, config):: $.fireeth.newFirehose(image, config {
      resources+: {
        disk: null,
      },
      service_account: config.service_account,
    }) {
      deployment+: k.util.mixinSTSContainer({
        name: 'substreams',
        [if config.discoveryServiceURL != '' then 'readinessProbe']: {
          failureThreshold: 3,
          initialDelaySeconds: 5,
          periodSeconds: 10,
          successThreshold: 1,
          tcpSocket: {
            port: 9000,
          },
          timeoutSeconds: 1,
        },
      }),
    },

    newSubstreamsTier2(image, config):: $.fireeth.newFirehose(image, config {
      resources+: {
        disk: null,
      },

      common_auth_plugin: '',
      relayer_address: '',
      service_account: config.service_account,
      substreams_client_endpoint: '',
      substreams_client_insecure: 'false',
      substreams_client_plaintext: 'false',
      substreams_partial_mode_enabled: 'true',
      substreams_sub_request_block_range_size: 0,
      substreams_sub_request_parallel_jobs: 0,
    }) {
      internalService: k.util.internalServiceFor(self.deployment, headless=true, exposedPort=9000),
      publicService: null,
      backendConfig: null,
    } + {
      deployment+: k.util.mixinSTSContainer({
        name: 'substreams',
        [if config.discoveryServiceURL != '' then 'readinessProbe']: {
          failureThreshold: 3,
          initialDelaySeconds: 5,
          periodSeconds: 10,
          successThreshold: 1,
          tcpSocket: {
            port: 9000,
          },
          timeoutSeconds: 1,
        },
      }),
    },

    newConsensusNode(image, config):: {
      local consensuseNode = self,

      local executionEndpoint = std.get(config, 'execution_endpoint', ''),
      local jwtSecret = std.get(config, 'jwt_secret', ''),
      local terminalTotalDifficulty = std.get(config, 'terminal_total_difficulty_override', null),

      configMap:
        configMap.new('%s-jwt' % config.name) +
        configMap.withDataMixin({
          'beacon-jwt-secret': jwtSecret,
        }),

      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('lighthouse', image) +
            container.withPorts([
              port.new('api', config.api_port),
              // This is actual both used for TCP and UDP, what's the proper way to deal with this?
              port.new('p2p', config.p2p_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand(std.prune([
              'lighthouse',
              'beacon',
              '--datadir=%s' % '/data',
              '--debug-level=info',
              '--network=%s' % config.network,
              '--listen-address=%s' % std.get(config, 'listen_address', '0.0.0.0'),
              '--port=%s' % std.get(config, 'p2p_port', '9000'),
              '--http',
              '--http-address=%s' % std.get(config, 'http_address', '0.0.0.0'),
              '--http-port=%s' % std.get(config, 'api_port', '5052'),
              '--metrics',
              '--metrics-address=%s' % std.get(config, 'metrics_address', '0.0.0.0'),
              '--metrics-port=%s' % std.get(config, 'metrics_port', '9102'),
              '--execution-jwt-id=%s' % std.get(config, 'execution-jwt-id', ''),
              (if std.get(config, 'checkpoint_sync_url') != null then '--checkpoint-sync-url=%s' % std.get(config, 'checkpoint_sync_url')),
              (if executionEndpoint != '' then '--execution-endpoint=%s' % executionEndpoint),
              (if jwtSecret != '' then '--execution-jwt=%s' % '/etc/consensus-node/beacon-jwt-secret'),
              (if terminalTotalDifficulty != null then '--terminal-total-difficulty-override=%s' % terminalTotalDifficulty),
            ])) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            // Not clear what should be the correct readiness probe here, what's the impact of using the API one?
            container.withHttpReadiness(config.api_port, path='/eth/v1/node/health'),
          ],
        ) +
        k.util.configMapVolumeMount(consensuseNode.configMap, '/etc/consensus-node') +
        k.util.stsServiceAccount(c.default_backup_write_account) +
        k.util.attachPVCTemplateFromDisk('datadir', config.resources.disk),

      service:
        k.util.internalServiceFor(self.statefulSet, false, true),
    },

    newReader(image, config):: {
      local reader = self,

      [if config.auth_jwt_secret != '' then 'configMap']:
        configMap.new('%s-jwt' % config.name) +
        configMap.withDataMixin({
          'beacon-jwt-secret': config.auth_jwt_secret,
        }),

      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('reader', image) +
            container.withPorts([
              port.new('grpc', c.default_grpc_port),
              port.new('prom-metrics', 9102),
              port.new('geth-metrics', 6061),
              port.new('rpc', config.rpc_port),
              port.new('rpc-auth', config.auth_port),
            ]) +
            container.withCommand([
              '/app/fireeth',
              'start',
              'reader-node',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              (if c.chain_id != 1 then '--common-chain-id=%d' % c.chain_id),
              '--common-network-id=%d' % c.network_id,
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--reader-node-data-dir=/data',
              '--reader-node-working-dir=/data/work',
              '--reader-node-readiness-max-latency=%ds' % config.readiness_max_latency_seconds,
              '--reader-node-log-to-zap=false',
              '--reader-node-debug-firehose-logs=false',
              '--reader-node-blocks-chan-capacity=1000',
              '--reader-node-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--reader-node-manager-api-addr=:8080',
              '--reader-node-arguments=%s' % config.arguments,
              '--reader-node-bootstrap-data-url=%s' % config.bootstrap_data_url,
              '--reader-node-enforce-peers=%s' % config.enforce_peers,
              '--reader-node-path=/app/geth',
              '--reader-node-type=geth',
              (if std.objectHas(config, 'backup_config') then '--reader-node-backups=%s' % config.backup_config),
            ]) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(8080) +
            container.lifecycle.postStart.exec.withCommand(['/bin/sh', '-c', 'rm -f /data/*/nodekey']),
          ],
        ) +
        { spec+: { template+: { metadata+: { annotations+: { 'prometheus.io.path': '/debug/metrics/prometheus' } } } } } +
        { spec+: { template+: { spec+: { terminationGracePeriodSeconds: 180 } } } } +
        (if config.auth_jwt_secret != '' then k.util.configMapVolumeMount(reader.configMap, '/etc/geth-config') else {}) +
        k.util.stsServiceAccount(c.default_blocks_write_account) +
        k.util.attachPVCTemplate(
          'datadir',
          config.resources.disk,
          config.resources.disk_storage_class,
          resize=std.objectHas(config.resources, 'disk_max'),
          resizeLimit=std.get(config.resources, 'disk_max', ''),
        ),

      internalService:
        k.util.internalServiceFor(self.statefulSet, publishNotReadyAddresses=true, headless=true),

      p2pShareService:
        service.new(
          '%s-p2p' % config.name,
          std.get(config, 'labels', {}) { name: config.name },
          [
            servicePort.newNamed('rpc', 8545, 8545) + servicePort.withProtocol('TCP'),
            servicePort.newNamed('rpc-auth', 8551, 8551) + servicePort.withProtocol('TCP'),
            servicePort.newNamed('p2p', 30303, 30303) + servicePort.withProtocol('TCP'),
          ],
        ),
    },

    newBackup(image, config):: {
      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('backup', image) +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand([
              '/app/fireeth',
              'start',
              'node',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              (if c.chain_id != 1 then '--common-chain-id=%d' % c.chain_id),
              '--common-network-id=%d' % c.network_id,
              '--node-role=peering',
              '--node-debug-firehose-logs=false',
              '--node-data-dir=/data',
              '--node-readiness-max-latency=%ds' % config.readiness_max_latency_seconds,
              '--node-log-to-zap=false',
              '--node-manager-api-addr=:8080',
              '--node-arguments=%s' % config.arguments,
              '--node-backups=%s' % config.backup_config,
              '--node-bootstrap-data-url=',
              '--node-path=/app/geth',
              '--node-type=geth',
            ]) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(8080) +
            container.lifecycle.postStart.exec.withCommand(['/bin/sh', '-c', 'rm -f /data/*/nodekey']),
          ],
        ) +
        k.util.stsServiceAccount(c.default_backup_write_account) +
        k.util.attachPVCTemplate(
          'datadir',
          config.resources.disk,
          config.resources.disk_storage_class,
          resize=std.objectHas(config.resources, 'disk_max'),
          resizeLimit=std.get(config.resources, 'disk_max', ''),
        ),

      internalService:
        k.util.internalServiceFor(self.statefulSet, publishNotReadyAddresses=true, headless=true),

      p2pShareService:
        service.new(
          '%s-p2p' % config.name,
          std.get(config, 'labels', {}) { name: config.name },
          [
            servicePort.newNamed('rpc', 8545, 8545) + servicePort.withProtocol('TCP'),
            servicePort.newNamed('rpc-auth', 8551, 8551) + servicePort.withProtocol('TCP'),
            servicePort.newNamed('p2p', 30303, 30303) + servicePort.withProtocol('TCP'),
          ],
        ),
    },

    newMiner(image, config):: {
      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('miner', image) +
            container.withPorts([
              port.new('http', 8080),
              port.new('rpc', 8545),
              port.new('p2p', 30303),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand([
              '/app/fireeth',
              'start',
              'node',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              (if c.chain_id != 1 then '--common-chain-id=%d' % c.chain_id),
              '--common-network-id=%d' % c.network_id,
              '--node-role=dev-miner',
              '--node-data-dir=/data',
              '--node-log-to-zap=false',
              '--node-manager-api-addr=:8080',
              '--node-arguments=%s' % config.arguments,
              '--node-bootstrap-data-url=%s' % config.bootstrap_data_url,
              '--node-path=/app/geth',
              '--node-type=geth',
            ]) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(8080),
          ],
        ) +
        k.util.stsServiceAccount(c.default_read_account) +
        k.util.attachPVCTemplate(
          'datadir',
          config.resources.disk,
          config.resources.disk_storage_class,
          resize=std.objectHas(config.resources, 'disk_max'),
          resizeLimit=std.get(config.resources, 'disk_max', ''),
        ),

      internalService:
        k.util.internalServiceFor(self.statefulSet),
    },

    newMerger(image, config):: {
      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('merger', image) +
            container.withPorts([
              port.new('prom-metrics', 9102),
              port.new('grpc', config.default_grpc_port),
            ]) +
            container.withCommand(std.prune([
              '/app/fireeth',
              'start',
              'merger',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--merger-prune-forked-blocks-after=%d' % config.prune_forked_blocks_after,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--merger-time-between-store-lookups=2s',
              '--merger-time-between-store-pruning=30s',
              '--common-forked-blocks-store-url=%s' % config.forked_blocks_url,
              '--merger-grpc-listen-addr=:%s' % config.default_grpc_port,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-one-block-store-url=%s' % config.one_blocks_url,
            ])) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account),

      internalService:
        k.util.internalServiceFor(self.statefulSet),
    },

    newRelayer(image, config):: {
      deployment:
        deployment.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          containers=[
            container.new('relayer', image) +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand(std.prune([
              '/app/fireeth',
              'start',
              'relayer',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--relayer-max-source-latency=%s' % config.max_source_latency,
              '--relayer-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--relayer-source=%s' % std.join(',', config.reader_addresses),
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
            ])) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) +
        k.util.stsServiceAccount(c.default_read_account),

      internalService:
        k.util.internalServiceFor(self.deployment),
    },

    newEvmExecutor(image, config):: {
      jsonRpc: if config.executor.enabled then {
        deployment:
          deployment.new(
            name='%s%s' % [config.executor.name, config.name_suffix],
            replicas=config.executor.replicas,
            labels=std.get(config, 'labels', {}),
            containers=[
              container.new('executor', image) +
              container.withPorts([
                port.new('jsonrpc', config.executor.listen_addr_port),
                port.new('prom-metrics', 9102),
              ]) +
              container.withCommand([
                '/app/executor',
                'serve',
                'json-rpc',
                '--listen-addr=%s' % config.executor.listen_addr,
                '--chain=%s' % config.executor.chain,
                if config.common_auth_plugin != '' then '--common-auth-plugin=%s' % config.common_auth_plugin,
                '--state-provider-dsn=%s' % config.executor.state_provider_dsn,
                '--timeout=%ss' % config.executor.timeout_sec,
                '--metrics-listen-addr=:9102',
              ]) +
              container.withEnvMap({
                DLOG: config.executor.dlog,
              } + config.extra_env_vars) +
              k.util.setResources(config.executor.resources) +
              container.withHealthzReadiness(config.executor.listen_addr_port),
            ],
          ) +
          k.util.stsServiceAccount(c.default_read_account),

        internalService:
          k.util.internalServiceFor(self.deployment),

        publicService:
          k.util.publicServiceFor(self.deployment, name=config.executor.name + '-public', backendConfig=config.executor.name),

        backendConfig:
          backendConfig.new(
            service=config.executor.name,
            mixin=backendConfig.mixin.spec.withTimeoutSec(config.executor.timeout_sec),
          ),

      },

      statedb: {
        local statedb_container = {
          new(name, kind, store_dsn, config)::
            local reproc = std.get(config, 'reproc', { enabled: false, mode: '' });

            container.new(name, image) +
            container.withPorts([
              port.new('prom-metrics', 9102),
              port.new('grpc', config.default_grpc_port),
            ]) +
            container.withCommand(
              [
                '/app/executor',
                'statedb',
                '--data-dir=/data',
                '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
                '--common-one-block-store-url=%s' % config.one_blocks_url,
                '--common-live-blocks-addr=%s' % config.relayer_address,
                '--enable-inject-mode=%s' % (if std.member(['indexer', 'hybrid'], kind) && !reproc.enabled then 'true' else 'false'),
                '--enable-server-mode=%s' % (if std.member(['server', 'hybrid'], kind) && !reproc.enabled then 'true' else 'false'),
                '--enable-reproc-sharder-mode=%s' % (if reproc.enabled && reproc.mode == 'sharder' then 'true' else 'false'),
                '--enable-reproc-injector-mode=%s' % (if reproc.enabled && reproc.mode == 'injector' && kind == 'indexer' then 'true' else 'false'),
                '--grpc-listen-addr=:%s' % config.default_grpc_port,
                '--metrics-listen-addr=:9102',
              ] +
              (
                if reproc.enabled then [
                  '--reproc-shard-count=%d' % reproc.shard_count,
                  '--reproc-shard-store-url=%s' % reproc.shards_store_url,
                ] else [
                ]
              ) +
              (
                if reproc.enabled && reproc.mode == 'sharder' then [
                  '--reproc-shard-scratch-directory=%s' % std.get(reproc, 'shard_scratch_directory', ''),
                  '--reproc-shard-start-block-num=%s' % reproc.start_block_num,
                  '--reproc-shard-stop-block-num=%s' % reproc.stop_block_num,
                ] else [
                ]
              ) +
              (
                if reproc.enabled && reproc.mode == 'injector' then [
                  '--reproc-injector-shard-index=%s' % reproc.shard_index,
                ] else [
                ]
              ) +
              [
                '--store-dsn=%s%s' % [store_dsn, std.get(config, 'store_dsn_params', '')],
              ]
            ) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources) +
            (if std.get(config.resources, 'disk', '') != '' then container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) else {}) +
            container.withHealthzReadiness(config.default_grpc_port),
        },

        local statedb_sts(name, kind, store_dsn, service_account, config) =
          sts.new(
            name=name,
            replicas=config.replicas,
            labels=std.get(config, 'labels', {}),
            serviceName=name,
            containers=[
              statedb_container.new(name, kind, store_dsn, config),
            ],
          ) +
          (
            if std.get(config.resources, 'disk', '') != '' then
              k.util.attachPVCTemplate(
                'datadir',
                config.resources.disk,
                config.resources.disk_storage_class,
                resize=std.get(config.resources, 'disk_max', '') != '',
                resizeLimit=std.get(config.resources, 'disk_max', ''),
              ) else
              {}

          ) +
          k.util.stsServiceAccount(service_account),

        local statedb_deployment(name, kind, store_dsn, service_account, config) =
          deployment.new(
            name=name,
            replicas=config.replicas,
            labels=std.get(config, 'labels', {}),
            containers=[
              statedb_container.new(name, kind, store_dsn, config),
            ],
          ) +
          k.util.stsServiceAccount(service_account),

        local indexer_config = config.statedb.indexer,
        local server_config = config.statedb.server,
        local hybrid_config = config.statedb.hybrid,

        indexer: if config.statedb.deployment == 'split' then {
          local reproc = std.get(config.statedb.indexer, 'reproc', { enabled: false, mode: '' }),
          local service_account = if reproc.enabled && reproc.mode == 'sharder' then c.default_blocks_write_account else c.default_db_write_account,

          statefulSet:
            statedb_sts('%s-indexer%s' % [config.statedb.name, config.name_suffix], 'indexer', config.store_dsn, service_account, indexer_config),

          internalService:
            k.util.internalServiceFor(self.statefulSet),
        },

        server: if config.statedb.deployment == 'split' then {
          statefulSet:
            statedb_deployment('%s-server%s' % [config.statedb.name, config.name_suffix], 'server', config.store_dsn, c.default_read_account, server_config),

          internalService:
            k.util.internalServiceFor(self.statefulSet),
        },

        hybrid: if config.statedb.deployment == 'single' then {
          statefulSet:
            statedb_sts('%s-hybrid%s' % [config.statedb.name, config.name_suffix], 'hybrid', config.store_dsn, c.default_db_write_account, hybrid_config),

          internalService:
            k.util.internalServiceFor(self.statefulSet),
        },
      },
    },

    newCombinedIndexBuilder(image, config):: {
      deployment:
        deployment.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          containers=[
            container.new('combined-index-builder', image) +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand([
              '/app/fireeth',
              'start',
              'combined-index-builder',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--combined-index-builder-grpc-listen-addr=%d' % config.default_grpc_port,
              '--combined-index-builder-index-size=%d' % config.index_size,
              '--common-block-index-sizes=%s' % std.join(',', config.lookup_index_sizes),
              '--combined-index-builder-start-block=%d' % config.start_block,
              (if config.stop_block > 0 then '--combined-index-builder-stop-block=%d' % config.stop_block),
              '--common-index-store-url=%s' % config.block_index_url,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
            ]) +
            container.withEnvMap({
              DLOG: config.dlog,
            } + config.extra_env_vars) +
            k.util.setResources(config.resources),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account),

      internalService:
        k.util.internalServiceFor(self.deployment),
    },

    public_interface: if c.public_interface != null then self.newGKEPublicInterface(c.public_interface),

    newGKEPublicInterface(config):: {
      ingress:
        ingress.new(name=config.name) +
        ingress.metadata.withAnnotations({
          'kubernetes.io/ingress.class': 'gce',
          'networking.gke.io/managed-certificates': std.join(', ', std.objectFields(config.managed_certs)),
        } + config.extra_annotations) +
        ingress.spec.withRules(std.map(function(rule) {
          host: rule.host,
          http: {
            paths: [ingress.path(path=path.path, service=path.service, port=path.port) for path in rule.paths],
          },
        }, config.rules)),

      certs_array::
        std.map(function(key) {
          key: key,
          value: k.gke.managedCertificate(key, config.managed_certs[key]),
        }, std.objectFields(config.managed_certs)),

      managed_certs: std.foldl(function(out, cert) out { [cert.key]: cert.value }, self.certs_array, {}),
    },

    limit_range: k.util.limitRange('Container', ['500m', '256Mi'], ['1', '512Mi'], name='mem-limit-range'),

    backup_role: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'Role',
      metadata: {
        name: 'snapshotter',
      },
      rules: [
        {
          apiGroups: [
            '*',
          ],
          resources: [
            'pods',
            'persistentvolumeclaims',
            'persistentvolumes',
          ],
          verbs: [
            'get',
          ],
        },
      ],
    },

    backup_rolebinding: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'RoleBinding',
      metadata: {
        name: 'snapshotter',
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'Role',
        name: 'snapshotter',
      },
      subjects: [
        { kind: 'ServiceAccount', name: acct }
        for acct in c.backup_service_accounts
      ],
    },

    monitor_role: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'Role',
      metadata: {
        name: 'prometheus-k8s',
      },
      rules: [
        {
          apiGroups: [
            '',
          ],
          resources: [
            'services',
            'endpoints',
            'pods',
          ],
          verbs: [
            'get',
            'list',
            'watch',
          ],
        },
      ],
    },

    monitor_rolebinding: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'RoleBinding',
      metadata: {
        name: 'prometheus-k8s',
      },
      roleRef: {
        apiGroup: 'rbac.authorization.k8s.io',
        kind: 'Role',
        name: 'prometheus-k8s',
      },
      subjects: [
        { kind: 'ServiceAccount', name: 'prometheus-k8s', namespace: 'monitoring' },
      ],
    },

  },
}
