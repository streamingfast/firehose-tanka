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

(import 'config.libsonnet') + {
  firearweave: {
    local c = $._config,
    local images = $._images,

    limit_range: k.util.limitRange('Container', ['500m', '256Mi'], ['1', '512Mi']),
    monitoring: k.util.monitoringRoles('monitoring'),
    reader: if c.reader != null then self.newReader(c.reader, images.reader),
    merger: if c.merger != null then self.newMerger(c.merger, images.merger),
    relayer: if c.relayer != null then self.newRelayer(c.relayer, images.relayer),
    firehose: if c.firehose != null then self.newFirehose(c.firehose, images.firehose),

    ingress: {
      [if c.fqdn != '' && std.get($.firearweave, 'firehose') != null then 'default']:
        ingress.new(name='default-ingress') +
        ingress.metadata.withAnnotations({
          'kubernetes.io/ingress.class': 'gce',
          'networking.gke.io/managed-certificates': std.join(', ', c.ingress_managed_certs),
        }) +
        ingress.spec.withRules(
          [{
            host: c.fqdn,
            http: {
              paths: [
                ingress.path(path='', service='firehose-prod', port=c.default_grpc_port),
              ],
            },
          }],
        ),
    },

    newReader(config, image):: {
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
              '/app/firearweave',
              'start',
              'reader-node',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-one-block-store-url=%s' % config.one_block_url,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--reader-node-data-dir=/data',
              '--reader-node-readiness-max-latency=%s' % config.readiness_max_latency,
              '--reader-node-log-to-zap=false',
              '--reader-node-debug-firehose-logs=false',
              '--reader-node-blocks-chan-capacity=1000',
              '--reader-node-stop-block-num=%s' % config.stop_block_num,
              '--reader-node-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--reader-node-manager-api-addr=:8080',
              '--reader-node-arguments=%s' % config.arguments,
              '--reader-node-path=/app/thegarii',
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withHealthzReadiness(8080),
          ],
        ) +
        k.util.stsServiceAccount(c.default_blocks_write_account) +
        k.util.attachPVCTemplate('datadir', config.resources.disk, config.resources.disk_storage_class, resizeLimit='32Gi'),

      internalService:
        k.util.internalServiceFor(self.statefulSet, publishNotReadyAddresses=true, headless=true),
    },

    newMerger(config, image):: {
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
              '/app/firearweave',
              'start',
              'merger',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-one-block-store-url=%s' % config.one_block_url,
              '--merger-grpc-listen-addr=:%s' % config.default_grpc_port,
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resources) +
            container.withVolumeMountsMixin([volumeMount.new('datadir', '/data')]) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) +
        k.util.attachPVCTemplate('datadir', config.resources.disk, config.storage_class) +
        k.util.stsServiceAccount(c.default_blocks_write_account),
      internalService:
        k.util.internalServiceFor(self.statefulSet),
    },

    newFirehose(config, image):: {
      local firehose = self,

      deployment:
        deployment.new(
          name=config.name,
          replicas=config.replicas,
          labels=std.get(config, 'labels', {}),
          containers=[
            container.new('firehose', image) +
            container.withImagePullPolicy('Always') +
            container.withPorts([
              port.new('grpc', config.default_grpc_port),
              port.new('prom-metrics', 9102),
            ]) +
            container.withCommand(std.prune([
              '/app/firearweave',
              'start',
              'firehose',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-blocks-cache-enabled=false',
              if config.common_auth_plugin != '' then '--common-auth-plugin=%s' % config.common_auth_plugin,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--common-live-source-addr=%s' % config.relayer_address,
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-one-block-store-url=%s' % config.one_block_url,
              '--common-system-shutdown-signal-delay=30s',
              '--firehose-grpc-listen-addr=:%d*' % config.default_grpc_port,
            ])) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resources) +
            container.withHealthzReadiness(config.default_grpc_port, ssl=true),
          ],
        ) +
        k.util.deployServiceAccount(c.default_read_account),

      internalService:
        k.util.internalServiceFor(self.deployment),

      [if config.fqdn != '' then 'externalAccess']: {
        publicService:
          k.util.publicServiceFor(
            firehose.deployment,
            name='firehose-prod',
            grpc_portnames=['firehose-grpc'],
            backendConfig=config.backendconfig_name,
          ),

        backendConfig:
          backendConfig.new(
            service=config.backendconfig_name,
            healthCheck=backendConfig.healthCheckHttps(port=config.default_grpc_port, requestPath='/healthz'),
            mixin=backendConfig.mixin.spec.withTimeoutSec(86400),
          ),

        managedCertificate: {
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
    },

    newRelayer(config, image):: {
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
              '/app/firearweave',
              'start',
              'relayer',
              '--config-file=',
              '--log-format=stackdriver',
              '--log-to-file=false',
              '--common-merged-blocks-store-url=%s' % config.merged_blocks_url,
              '--common-one-block-store-url=%s' % config.one_block_url,
              '--common-first-streamable-block=%s' % config.first_streamable_block,
              '--relayer-max-source-latency=%s' % config.max_source_latency,
              '--relayer-grpc-listen-addr=:%d' % config.default_grpc_port,
              '--relayer-source=%s' % std.join(',', config.reader_addresses),
            ]) +
            container.withEnvMap({
              INFO: '.*',
            }) +
            k.util.setResources(config.resources) +
            container.withGRPCReadiness(config.default_grpc_port),
          ],
        ) + k.util.stsServiceAccount(config.default_read_account),

      internalService:
        k.util.internalServiceFor(self.deployment),
    },
  },
}
