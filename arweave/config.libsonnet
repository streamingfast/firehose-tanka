local tk = import 'tk';

(import 'images.libsonnet') + {
  _config: {
    local c = self,
    namespace: tk.env.spec.namespace,

    first_streamable_block: 0,

    fqdn: error 'you must set an fqdn (or empty string to skip creating managedCertificate and ingress)',
    version_tag: error 'you must set a resources version tag, ex: v3',
    blocks_version: error 'you must set a blocks version version tag, ex: v3',
    default_storage_url_prefix: error 'you must set default_storage_prefix (ex: gs://my-bucket)',
    ingress_managed_certs: std.prune([std.strReplace(self.fqdn, '.', '-')]),

    storage_class: 'gcpssd-lazy',
    volume_mode: 'Filesystem',
    default_grpc_port: 9000,
    default_blocks_write_account: '',
    default_read_account: '',
    common_auth_plugin: '',

    relayer_address: 'dns:///relayer-%s:%d' % [self.version_tag, self.default_grpc_port],
    merger_address: 'dns:///merger-%s:%d' % [self.version_tag, self.default_grpc_port],
    reader_addresses: [
      'dns:///reader-v1-0.reader-v1:%d' % self.default_grpc_port,
    ],

    mergedBlockStoreUrl(config, version):: {
      url: '%s/%s%s' % [
        config.default_storage_url_prefix,
        config.namespace,
        '/' + version,
      ],
    },
    merged_blocks_url: c.mergedBlockStoreUrl(c, c.blocks_version).url,
    oneBlocksUrl(config, version):: {
      url: config.mergedBlockStoreUrl(config, version).url + '-oneblock',
    },
    one_block_url: c.oneBlocksUrl(c, c.blocks_version).url,

    // resource base configuration
    reader: {
      name: 'reader-%s' % c.version_tag,
      replicas: 2,
      resources: {
        requests: error 'resources.requests must be set',
        limits: error 'resources.limits must be set',
        disk: error 'resources.disk must be set',
        disk_storage_class: c.storage_class,
      },

      one_block_url: c.one_block_url,
      merged_blocks_url: c.merged_blocks_url,
      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      readiness_max_latency: '1h',
      arguments: '--endpoints=https://arweave.net/ -B 2 -c 20 console --data-directory=/data/thegarii -s 900000 --forever',
      start_block_num: 0,
      stop_block_num: 0,
    },

    merger: {
      name: 'merger-%s' % c.version_tag,
      replicas: 1,
      resources: {
        requests: error 'resources.requests must be set',
        limits: error 'resources.limits must be set',
      },

      one_block_url: c.one_block_url,
      merged_blocks_url: c.merged_blocks_url,
      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      storage_class: c.storage_class,
      common_auth_plugin: c.common_auth_plugin,
    },

    firehose: {
      name: 'firehose-%s' % c.version_tag,
      replicas: 2,
      resources: {
        requests: error 'resources.requests must be set',
        limits: error 'resources.limits must be set',
      },

      storage_class: c.storage_class,
      default_grpc_port: c.default_grpc_port,
      first_streamable_block: c.first_streamable_block,
      common_auth_plugin: c.common_auth_plugin,
      relayer_address: c.relayer_address,
      merged_blocks_url: c.merged_blocks_url,
      one_block_url: c.one_block_url,
      backendconfig_name: 'streamingfast-backendconfig',
      fqdn: c.fqdn,
    },

    relayer: {
      name: 'relayer-%s' % c.version_tag,
      replicas: 2,
      resources: {
        requests: error 'resources.requests must be set',
        limits: error 'resources.limits must be set',
      },

      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      max_source_latency: '1h',
      reader_addresses: c.reader_addresses,
      one_block_url: c.one_block_url,
      merged_blocks_url: c.merged_blocks_url,
      default_read_account: c.default_read_account,
    },
  },
}
