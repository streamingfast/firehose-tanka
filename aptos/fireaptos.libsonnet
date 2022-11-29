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
local backendConfig = k.core.v1.backendConfig;

local isRemoteFile(object, key) =
  std.startsWith(std.get(object, key, ''), 'http://') || std.startsWith(std.get(object, key, ''), 'https://');

local isConfigMapFile(object, key) =
  std.get(object, key, '') != '' && !isRemoteFile(object, key);

(import 'config.libsonnet') + {
  local c = $._config,
  local images = $._images,

  limit_range: k.util.limitRange('Container', ['500m', '256Mi'], ['1', '512Mi']),
  monitoring: k.util.monitoringRoles('monitoring'),

  fireaptos: {
    newReader(image, config):: {
      local reader = self,

      // If `config[key]` is unset or null, '' is returned right away. If `config[key]` is a remote
      // file (i.e. it starts with either 'http://' or 'https://'), it's returned
      // as-is. Otherwise, it's assumed to be content of the file directly in which case the
      // '/etc/aptos-node/<filepath>' value is returned (a ConfigMap item will be mounted).
      local fileArgument(config, key, filepath) =
        if isConfigMapFile(config, key) then '/etc/aptos-node/%s' % filepath else std.get(config, key, ''),

      configMap:
        configMap.new('%s-configs' % config.name) +
        configMap.withDataMixin({
          'node-config.yaml': config.node_config,
          [if isConfigMapFile(config, 'node_validator_identity') then 'validator-identity.yaml']: config.node_validator_identity,
          [if isConfigMapFile(config, 'node_vfn_identity') then 'vfn-identity.yaml']: config.node_vfn_identity,
          [if isConfigMapFile(config, 'node_waypoint') then 'waypoint.tx']: config.node_waypoint,
        }) +
        configMap.withBinaryDataMixin({
          // Content should already be base64 data for all fields
          [if isConfigMapFile(config, 'node_genesis') then 'genesis.blob']: config.node_genesis,
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
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand([
              '/app/fireaptos',
              'start',
              'reader-node',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--reader-node-arguments=%s' % config.arguments,
              '--reader-node-blocks-chan-capacity=1000',
              '--reader-node-config-file=/etc/aptos-node/node-config.yaml',
              '--reader-node-data-dir=/data',
              '--reader-node-debug-firehose-logs=false',
              '--reader-node-discard-after-stop-num=false',
              '--reader-node-genesis-file=%s' % fileArgument(config, 'node_genesis', 'genesis.blob'),
              '--reader-node-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--reader-node-log-to-zap=false',
              '--reader-node-manager-api-addr=:9090',
              '--reader-node-path=/app/aptos-node',
              '--reader-node-readiness-max-latency=%ds' % config.readiness_max_latency_seconds,
              '--reader-node-start-block-num=%s' % config.start_block_num,
              '--reader-node-stop-block-num=%s' % config.stop_block_num,
              '--reader-node-working-dir=%s' % config.working_directory,
              '--reader-node-validator-identity-file=%s' % fileArgument(config, 'node_validator_identity', 'validator-identity.yaml'),
              '--reader-node-vfn-identity-file=%s' % fileArgument(config, 'node_vfn_identity', 'vfn-identity.yaml'),
              '--reader-node-waypoint-file=%s' % fileArgument(config, 'node_waypoint', 'waypoint.txt'),
            ]) +
            container.withEnvMap({
              INFO: '.*',
              RUST_LOG: 'INFO',
            }) +
            k.util.setResources(config.resource) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(9090),
          ],
        ) +
        k.util.configMapVolumeMount(reader.configMap, '/etc/aptos-node') +
        k.util.stsServiceAccount(c.default_blocks_write_account) +
        k.util.attachPVCTemplateFromDisk('datadir', std.get(config.resource, 'disk')),

      internalService:
        k.util.internalServiceFor(self.statefulSet, publishNotReadyAddresses=true, headless=true),

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
            container.withCommand([
              '/app/fireaptos',
              'start',
              'merger',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--merger-grpc-listen-addr=:%s' % config.default_grpc_port,
              '--merger-prune-forked-blocks-after=%s' % config.prune_forked_blocks_after,
              '--merger-time-between-store-lookups=%s' % config.time_between_store_lookups,
              '--merger-time-between-store-pruning=%s' % config.time_between_store_pruning,
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resource) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account),

      internalService:
        k.util.internalServiceFor(self.statefulSet),
    },

    newFirehose(image, config):: {
      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=std.get(config, 'service_name', config.name),
          containers=[
            container.new('firehose', image) +
            container.withImagePullPolicy(std.get(config, 'image_pull_policy', 'IfNotPresent')) +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand(
              std.prune([
                '/app/fireaptos',
                'start',
                'firehose',
                '--config-file=',
                '--log-format=stackdriver',
                '--log-to-file=false',
                '--common-blocks-cache-enabled=%s' % config.blocks_cache_enabled,
                '--common-blocks-cache-dir=/data',
                '--common-blocks-cache-max-recent-entry-bytes=%d' % config.blocks_cache_recent_bytes,
                '--common-blocks-cache-max-entry-by-age-bytes=%d' % config.blocks_cache_age_bytes,
                (if config.common_auth_plugin != '' then '--common-auth-plugin=%s' % config.common_auth_plugin),
                '--common-live-blocks-addr=%s' % config.relayer_address,
                '--common-system-shutdown-signal-delay=%s' % config.common_system_shutdown_signal_delay,
                '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
                (if config.first_streamable_block != 0 then '--common-first-streamable-block=' + config.first_streamable_block),
                '--common-one-block-store-url=%s' % config.one_blocks_url,
                '--firehose-grpc-listen-addr=:%d*' % config.default_grpc_port,
                '--firehose-real-time-tolerance=%s' % config.real_time_tolerance,
              ]) +
              (
                if !config.substreams_enabled then [] else
                  [
                    '--substreams-client-endpoint=%s' % config.substreams_client_endpoint,
                    '--substreams-client-insecure=%s' % config.substreams_client_insecure,
                    '--substreams-client-plaintext=%s' % config.substreams_client_plaintext,
                    '--substreams-enabled=%s' % config.substreams_enabled,
                    '--substreams-output-cache-save-interval=%s' % config.substreams_output_cache_save_interval,
                    '--substreams-partial-mode-enabled=%s' % config.substreams_partial_mode_enabled,
                    '--substreams-state-store-url=%s' % config.substreams_state_store_url,
                    '--substreams-stores-save-interval=1000',
                    '--substreams-sub-request-block-range-size=%s' % config.substreams_sub_request_block_range_size,
                    '--substreams-sub-request-parallel-jobs=%s' % config.substreams_sub_request_parallel_jobs,
                  ]
              )
            ) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resource) +
            k.util.withVolumeMountsFromDiskIfSet('datadir', '/data', std.get(config.resource, 'disk')) +
            container.withHealthzReadiness(config.default_grpc_port, ssl=true),
          ],
        ) +
        k.util.stsServiceAccount(std.get(config, 'service_account', c.default_read_account)) +
        k.util.runOnNodePoolOnlyIfSet(std.get(config, 'node_pool')) +
        k.util.attachPVCTemplateFromDiskIfSet('datadir', std.get(config.resource, 'disk')),

      internalService:
        k.util.internalServiceFor(self.statefulSet),

    },

    newSubstreams(image, config)::
      $.fireaptos.newFirehose(image, config {
        resource+: {
          disk: null,
        },

        common_auth_plugin: '',
        relayer_address: '',
        service_account: std.get(config, 'service_account', c.default_blocks_write_account),
        substreams_client_endpoint: '',
        substreams_client_insecure: 'false',
        substreams_client_plaintext: 'false',
        substreams_partial_mode_enabled: 'true',
        substreams_sub_request_block_range_size: '0',
        substreams_sub_request_parallel_jobs: '0',
      }) {
        internalService: k.util.internalServiceFor(self.statefulSet, headless=true),
        publicService: null,
        backendConfig: null,
      } + { statefulSet+: k.util.mixinSTSContainer({ name: 'substreams' }) },

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
            container.withCommand([
              '/app/fireaptos',
              'start',
              'relayer',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--relayer-max-source-latency=%s' % config.max_source_latency,
              '--relayer-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--relayer-source=%s' % std.join(',', config.reader_addresses),
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resource) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) + k.util.stsServiceAccount(config.default_read_account),

      internalService:
        k.util.internalServiceFor(self.deployment),
    },
  },
}
