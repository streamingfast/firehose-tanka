local k = import 'sf/k8s.libsonnet';  // some constructor overrides over grafana's "kausal"

//// Reference documentation to find the right thing to call https://jsonnet-libs.github.io/k8s-libsonnet/1.20
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
local GiB = (1024 * 1024 * 1024);

(import 'config.libsonnet') + {
  firesol: {
    local c = $._config,
    local images = $._images,

    limit_range: k.util.limitRange('Container', ['500m', '256Mi'], ['1', '512Mi'], name='mem-limit-range'),
    monitoring: k.util.monitoringRoles('monitoring'),

    merger: if std.get(c, 'merger') != null then self.newMerger(images.merger, c.merger),
    relayer: if std.get(c, 'relayer') != null then self.newRelayer(images.relayer, c.relayer),
    firehose: if std.get(c, 'firehose') != null then self.newFirehose(images.firehose, c.firehose),
    ingress: if std.get(c, 'fqdn', '') != '' then self.newIngress('default-ingress', c.fqdn, c.firehose.name, c.default_grpc_port, c.ingress_managed_certs),


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
              '/app/firesol',
              'start',
              'merger',
              '--config-file=',
              '--augmented-mode=%s' % config.augmentedData,
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--merger-time-between-store-lookups=5s',
              '--merger-time-between-store-pruning=30s',
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--merger-grpc-listen-addr=:%s' % config.default_grpc_port,
              '--common-forked-blocks-store-url=%s' % config.forked_blocks_url,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-one-block-store-url=%s' % config.one_blocks_url,
            ])) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account) +
        k.util.attachPVCTemplate(
          'datadir',
          config.resources.disk,
          config.resources.disk_storage_class,
          resize=std.objectHas(config.resources, 'disk_max'),
          resizeLimit=std.get(config.resources, 'disk_max', ''),
        ),

      monitorService:
        k.util.monitorServiceFor(self.statefulSet),

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
            container.withCommand([
              '/app/firesol',
              'start',
              'relayer',
              '--config-file=',
              '--augmented-mode=%s' % config.augmentedData,
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--relayer-max-source-latency=5m',
              '--relayer-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--relayer-source=%s' % std.join(',', config.reader_addresses),
              '--common-one-block-store-url=%s' % config.one_blocks_url,
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resources) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) + k.util.stsServiceAccount(config.default_read_account),

      monitorService:
        k.util.monitorServiceFor(self.deployment),

      internalService:
        k.util.internalServiceFor(self.deployment),
    },

    newFirehose(image, config):: {
      statefulSet:
        sts.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          serviceName=config.name,
          containers=[
            container.new('firehose', image) +
            container.withImagePullPolicy('Always') +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand(std.prune([
              '/app/firesol',
              'start',
              'firehose',
              '--config-file=',
              '--augmented-mode=%s' % config.augmentedData,
              '--log-format=stackdriver',
              '--log-to-file=false',
              (if config.cache_recent_bytes == 0 && config.cache_age_bytes == 0 then '--common-blocks-cache-enabled=false' else '--common-blocks-cache-enabled'),
              '--common-blocks-cache-dir=/data',
              '--common-blocks-cache-max-recent-entry-bytes=%d' % config.cache_recent_bytes,
              '--common-blocks-cache-max-entry-by-age-bytes=%d' % config.cache_age_bytes,
              if config.common_auth_plugin != '' then '--common-auth-plugin=%s' % config.common_auth_plugin,
              '--common-live-blocks-addr=%s' % config.relayer_address,
              '--common-system-shutdown-signal-delay=30s',
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-forked-blocks-store-url=%s' % config.forked_blocks_url,
              '--firehose-grpc-listen-addr=:%d*' % config.default_grpc_port,
              (if config.discoveryServiceURL != '' then '--firehose-discovery-service-url=%s' % config.discoveryServiceURL),
              '--substreams-client-endpoint=%s' % config.client_endpoint,
              '--common-first-streamable-block=%d' % config.first_streameable_block,
              '--substreams-enabled=%s' % config.substream_enabled,
              '--substreams-client-jwt=%s' % config.client_jwt,
              '--substreams-client-insecure=true',
              '--substreams-client-plaintext=false',
              '--substreams-state-store-url=%s' % config.state_store_url,
              '--substreams-sub-request-block-range-size=10000',
              '--substreams-sub-request-parallel-jobs=%d' % config.parallel_jobs,
            ])) +
            container.withEnvMap({
              INFO: '.*',
              [if config.discoveryServiceURL != '' then 'GRPC_XDS_BOOTSTRAP']: '/tmp/bootstrap.json',
            }) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(config.default_grpc_port, ssl=true),
          ],
        ) +
        k.util.stsServiceAccount(if config.substream_enabled then c.default_blocks_write_account else c.default_read_account) +
        k.util.attachPVCTemplate(
          'datadir',
          config.resources.disk,
          config.resources.disk_storage_class,
          resize=std.objectHas(config.resources, 'disk_max'),
          resizeLimit=std.get(config.resources, 'disk_max', ''),
        ) +
        k.util.runOnNodePoolAndZoneOnlyIfSet(
          std.get(config, 'zone'),
          std.get(config, 'node_pool')
        ),

      service:
        k.util.publicServiceFor(self.statefulSet, grpc_portnames=['firehose-grpc'], backendConfig=config.backendconfig_name),

      monitorService:
        k.util.monitorServiceFor(self.statefulSet),

      backendConfig:
        backendConfig.new(
          service=config.backendconfig_name,
          healthCheck=backendConfig.healthCheckHttps(port=config.default_grpc_port, requestPath='/healthz'),
          mixin=backendConfig.mixin.spec.withTimeoutSec(86400),
        ),

      [if config.fqdn != '' then 'managedCertificate']: {
        apiVersion: 'networking.gke.io/v1',
        kind: 'ManagedCertificate',
        metadata: {
          name: std.strReplace(config.fqdn, '.', '-'),
        },
        spec: {
          domains: [config.fqdn],
        },
      },
    },

    newSubstreams(image, config):: {
      deployment:
        deployment.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          containers=[
            container.new('substreams', image) +
            container.withPorts([
              port.new('grpc', c.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand(
              std.prune(
                [
                  '/app/firesol',
                  'start',
                  'firehose',
                  '--config-file=',
                  '--log-format=stackdriver',
                  '--log-to-file=false',
                  (if config.cache_recent_bytes == 0 && config.cache_age_bytes == 0 then '--common-blocks-cache-enabled=false' else '--common-blocks-cache-enabled'),
                  '--common-blocks-cache-dir=/data',
                  '--common-blocks-cache-max-recent-entry-bytes=%d' % config.cache_recent_bytes,
                  '--common-blocks-cache-max-entry-by-age-bytes=%d' % config.cache_age_bytes,
                  '--common-live-blocks-addr=',
                  '--common-system-shutdown-signal-delay=0',
                  '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
                  '--firehose-grpc-listen-addr=:%d*' % config.default_grpc_port,
                  (if config.discoveryServiceURL != '' then '--firehose-discovery-service-url=%s' % config.discoveryServiceURL),
                  '--substreams-enabled',
                  '--substreams-state-store-url=%s' % config.state_store_url,
                  '--substreams-stores-save-interval=1000',
                  '--substreams-output-cache-save-interval=100',
                  '--substreams-partial-mode-enabled',
                ]
              )
            ) +
            container.withEnvMap({
              INFO: '.*',
              SUBSTREAMS_SEND_HOSTNAME: 'true',
              [if config.discoveryServiceURL != '' then 'GRPC_XDS_BOOTSTRAP']: '/tmp/bootstrap.json',
            }) +
            k.util.setResources(config.resources) +
            container.withHealthzReadiness(c.default_grpc_port, ssl=true),
          ],
        ) + k.util.mixinSTSContainer({
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
        }) +
        k.util.deployServiceAccount(c.default_blocks_write_account) +
        k.util.runOnNodePoolAndZoneOnlyIfSet(
          std.get(config, 'zone'),
          std.get(config, 'node_pool')
        ),

      service:
        k.util.internalServiceFor(self.deployment, false, true, config.default_grpc_port),

      monitorService:
        k.util.monitorServiceFor(self.deployment),
    },

    newReaderBT(image, config):: {
      local reader_bt = self,

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
            ]) +
            container.withCommand([
              '/app/firesol',
              'start',
              'reader-bt',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-one-block-store-url=%s' % config.one_blocks_url,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--reader-bt-readiness-max-latency=%ds' % config.readiness_max_latency_seconds,
              '--reader-bt-data-dir=/data',
              '--reader-bt-debug-firehose-logs=false',
              '--reader-bt-startup-delay=0',
              '--reader-bt-log-to-zap=false',
              '--reader-bt-working-dir=/data/work',
              '--reader-bt-blocks-chan-capacity=1000',
              '--reader-bt-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--reader-bt-project-id=mainnet-beta',
              '--reader-bt-instance-id=solana-ledger',
              '--reader-bt-manager-listen-addr=:8080',
              '--common-first-streamable-block=%s' % config.first_streamable_block,
            ]) +
            container.withEnvMap({
              INFO: '.*',
              GOOGLE_APPLICATION_CREDENTIALS: '/var/secrets/google/service_account.json',
            }) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(8080) +
            container.lifecycle.postStart.exec.withCommand(['/bin/sh', '-c', 'rm -f /data/*/nodekey']),
          ],
        ) +
        { spec+: { template+: { metadata+: { annotations+: { 'prometheus.io.path': '/debug/metrics/prometheus' } } } } } +
        { spec+: { template+: { spec+: { terminationGracePeriodSeconds: 180 } } } } +
        k.util.secretVolumeMount('solana-bigtable-sa', '/var/secrets/google', 420) +
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

    },

    newIngress(name, fqdn, firehose_svc_name, grpc_port, managed_certs)::
      ingress.new(name=name) +
      ingress.metadata.withAnnotations({
        'kubernetes.io/ingress.class': 'gce',
        'networking.gke.io/managed-certificates': std.join(', ', managed_certs),
      }) +
      ingress.spec.withRules(
        [{
          host: fqdn,
          http: {
            paths: [
              ingress.path(path='', service=firehose_svc_name, port=grpc_port),
            ],
          },
        }],
      ),
  },
}
