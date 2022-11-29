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

(import 'config.libsonnet') + {
  firenear: {
    local c = $._config,
    local images = $._images,

    limit_range: k.util.limitRange('Container', ['500m', '256Mi'], ['1', '512Mi']),
    monitoring: k.util.monitoringRoles('monitoring'),
    extractor: if c.extractor != null then self.newExtractor(images.extractor, c.extractor),
    archive: if c.archive != null then self.newArchive(images.archive, c.archive),
    merger: if c.merger != null then self.newMerger(images.merger, c.merger),
    relayer: if c.relayer != null then self.newRelayer(images.relayer, c.relayer),
    firehose: if c.firehose != null then self.newFirehose(images.firehose, c.firehose),
    receipt_index_builder: if c.receipt_index_builder != null then self.newReceiptIndexBuilder(images.receipt_index_builder, c.receipt_index_builder),

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

    newArchive(image, config):: {
      local extractor = self,

      //configMap:
      //  configMap.new('%s-configs' % config.name) +
      //  configMap.withDataMixin({
      //    'node-config.yaml': config.node_config,
      //    'validator-identity.yaml': config.node_validator_identity,
      //    'vfn-identity.yaml': config.node_vfn_identity,
      //  }) +
      //  configMap.withBinaryDataMixin({
      //    // Content should already by base64 data
      //    'genesis.blob': config.node_genesis,
      //  }),

      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('archive', image) +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand([
              '/app/firenear',
              'start',
              'archive-node',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--archive-node-data-dir=/data',
              '--archive-node-log-to-zap=false',
              '--archive-node-backups=%s' % config.backup_config,
              '--archive-node-manager-api-addr=:8080',
              '--archive-node-path=/app/neard',
              '--archive-node-readiness-max-latency=%ds' % config.readiness_max_latency_seconds,
              '--archive-node-config-file=%s' % config.node_config_file,
              '--archive-node-genesis-file=%s' % config.node_genesis_file,
              '--archive-node-node-key-file=%s' % config.node_key_file,
              '--archive-node-overwrite-node-files',
              '--archive-node-arguments=',
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resource) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(8080),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account) +
        k.util.runOnNodePoolOnlyIfSet(std.get(config, 'node_pool')) +
        k.util.attachPVCTemplate('datadir', config.resource.disk, config.resource.disk_storage_class),

      internalService:
        k.util.internalServiceFor(self.statefulSet, publishNotReadyAddresses=true, headless=true),

      monitorService:
        k.util.monitorServiceFor(self.statefulSet),
    },

    newExtractor(image, config):: {
      local extractor = self,

      //configMap:
      //  configMap.new('%s-configs' % config.name) +
      //  configMap.withDataMixin({
      //    'node-config.yaml': config.node_config,
      //    'validator-identity.yaml': config.node_validator_identity,
      //    'vfn-identity.yaml': config.node_vfn_identity,
      //  }) +
      //  configMap.withBinaryDataMixin({
      //    // Content should already by base64 data
      //    'genesis.blob': config.node_genesis,
      //  }),

      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('extractor', image) +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand(std.prune([
              '/app/firenear',
              'start',
              'reader-node',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              (if std.objectHas(config, 'backup_config') then '--reader-node-backups=%s' % config.backup_config),
              '--reader-node-data-dir=/data',
              '--reader-node-blocks-chan-capacity=1000',
              '--reader-node-debug-firehose-logs=false',
              '--reader-node-log-to-zap=false',
              '--reader-node-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--reader-node-manager-api-addr=:8080',
              '--reader-node-path=/app/near-firehose-indexer',
              '--reader-node-working-dir=/data/work',
              '--reader-node-readiness-max-latency=%ds' % config.readiness_max_latency_seconds,
              '--reader-node-config-file=%s' % config.node_config_file,
              '--reader-node-genesis-file=%s' % config.node_genesis_file,
              '--reader-node-node-key-file=%s' % config.node_key_file,
              '--reader-node-overwrite-node-files',
              '--reader-node-arguments=',
            ])) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resource) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(8080),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account) +
        k.util.runOnNodePoolOnlyIfSet(std.get(config, 'node_pool')) +
        k.util.attachPVCTemplate('datadir', config.resource.disk, config.resource.disk_storage_class),

      internalService:
        k.util.internalServiceFor(self.statefulSet, publishNotReadyAddresses=true, headless=true),

      monitorService:
        k.util.monitorServiceFor(self.statefulSet),
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
              '/app/firenear',
              'start',
              'merger',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--common-forked-blocks-store-url=%s' % config.forked_blocks_url,
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
        k.util.runOnNodePoolOnlyIfSet(std.get(config, 'node_pool')) +
        k.util.stsServiceAccount(c.default_blocks_write_account),

      monitorService:
        k.util.monitorServiceFor(self.statefulSet),

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
                '/app/firenear',
                'start',
                'firehose',
                '--config-file=',
                '--log-format=stackdriver',
                '--log-to-file=false',
                if config.cache_enabled then '--common-blocks-cache-enabled' else '--common-blocks-cache-enabled=false',
                '--common-blocks-cache-dir=/data',
                '--common-blocks-cache-max-recent-entry-bytes=%d' % config.cache_recent_bytes,
                '--common-blocks-cache-max-entry-by-age-bytes=%d' % config.cache_age_bytes,
                if config.common_auth_plugin != '' then '--common-auth-plugin=%s' % config.common_auth_plugin,
                '--common-system-shutdown-signal-delay=%s' % config.common_system_shutdown_signal_delay,
                '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
                '--common-live-blocks-addr=%s' % config.common_blockstream_addr,
                (if config.first_streamable_block != 0 then '--common-first-streamable-block=' + config.first_streamable_block),
                '--common-one-block-store-url=%s' % config.one_blocks_url,
                '--firehose-grpc-listen-addr=:%d*' % config.default_grpc_port,
                '--firehose-block-index-url=%s' % config.indexed_blocks_url,
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
        k.util.runOnZoneOnlyIfSet(std.get(config, 'zone')) +
        k.util.attachPVCTemplateFromDiskIfSet('datadir', std.get(config.resource, 'disk')),

      monitorService:
        k.util.monitorServiceFor(self.statefulSet),

      publicService:
        k.util.publicServiceFor(self.statefulSet, grpc_portnames=['firehose-grpc'], backendConfig=config.backend_config_name),

      backendConfig:
        backendConfig.new(
          service=config.backend_config_name,
          healthCheck=backendConfig.healthCheckHttps(port=config.default_grpc_port, requestPath='/healthz'),
          mixin=backendConfig.mixin.spec.withTimeoutSec(86400),
        ),
    },

    newSubstreams(image, config)::
      $.firenear.newFirehose(image, config {
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
              '/app/firenear',
              'start',
              'relayer',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--relayer-max-source-latency=%s' % config.max_source_latency,
              '--relayer-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--relayer-source=%s' % std.join(',', config.extractor_addresses),
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resource) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) + k.util.stsServiceAccount(config.default_read_account) +
        k.util.runOnNodePoolOnlyIfSet(std.get(config, 'node_pool')),

      monitorService:
        k.util.monitorServiceFor(self.deployment),

      internalService:
        k.util.internalServiceFor(self.deployment),
    },

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

    newReceiptIndexBuilder(image, config):: {
      deployment:
        deployment.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          containers=[
            container.new('receipt-index-builder', image) +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand([
              '/app/firenear',
              'start',
              'receipt-index-builder',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--receipt-index-builder-index-size=%d' % config.index_size,
              '--receipt-index-builder-lookup-index-sizes=%s' % std.join(',', config.lookup_index_sizes),
              '--receipt-index-builder-start-block=%d' % config.start_block,
              (if config.stop_block > 0 then '--receipt-index-builder-stop-block=%d' % config.stop_block),
              '--receipt-index-builder-index-store-url=%s' % config.indexed_blocks_url,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              (if config.first_streamable_block != 0 then '--common-first-streamable-block=' + config.first_streamable_block),
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resources),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account) +
        k.util.runOnNodePoolOnlyIfSet(std.get(config, 'node_pool')),

      monitorService:
        k.util.monitorServiceFor(self.deployment),

      internalService:
        k.util.internalServiceFor(self.deployment),
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
  },
}
