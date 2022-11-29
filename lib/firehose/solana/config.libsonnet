local tk = import 'tk';
local MiB = (1024 * 1024);
local GiB = (1024 * 1024 * 1024);

local append(name, tag) = (if tag == '' then name else '%s-%s' % [name, tag]);

(import 'images.libsonnet') + {
  _config: {
    local c = self,
    namespace: tk.env.spec.namespace,

    fqdn: error 'you must set an fqdn (or empty string to skip creating managedCertificate and ingress)',
    version_tag: error 'you must set a resources version tag, ex: v3',
    blocks_version: error 'you must set a blocks version version tag, ex: v3',
    substreams_states_version: error 'you must set a blocks version version tag, ex: v3',
    default_storage_url_prefix: error 'you must set default_storage_prefix (ex: gs://my-bucket)',
    ingress_managed_certs: std.prune([std.strReplace(self.fqdn, '.', '-')]),
    substreams_state_store_url: '%s/%s/%s' % [
      c.default_storage_url_prefix,
      c.namespace,
      'substreams-states/%s' % c.substreams_states_version,
    ],

    storage_class: 'gcpssd-lazy',
    volume_mode: 'Filesystem',
    default_grpc_port: 9000,
    default_blocks_write_account: '',
    default_read_account: '',
    common_auth_plugin: '',
    node_readiness_max_latency_seconds: 600,
    first_streamable_block: 0,
    augmentedData: false,

    relayer_address: 'dns:///relayer-%s:%d' % [self.version_tag, self.default_grpc_port],
    merger_address: 'dns:///merger-%s:%d' % [self.version_tag, self.default_grpc_port],

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
    one_blocks_url: c.oneBlocksUrl(c, c.blocks_version).url,
    forked_blocks_url: self.merged_blocks_url + '-forked',

    // resource base configuration
    merger: {
      name: 'merger-%s' % c.version_tag,
      replicas: 1,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: '1Gi',
        disk_storage_class: c.storage_class,
      },

      augmentedData: c.augmentedData,
      storage_class: c.storage_class,
      default_grpc_port: c.default_grpc_port,
      common_auth_plugin: c.common_auth_plugin,
      merged_blocks_url: c.merged_blocks_url,
      one_blocks_url: c.one_blocks_url,
      forked_blocks_url: c.forked_blocks_url,
      first_streamable_block: c.first_streamable_block,
    },

    substreams: {
      name: 'substreams-%s' % c.version_tag,
      replicas: 2,

      resourcesf: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_storage_class: c.storage_class,
      },

      discoveryServiceURL: '',
      node_pool: '',
      cache_age_bytes: 2 * GiB,
      cache_recent_bytes: 2 * GiB,
      default_grpc_port: c.default_grpc_port,
      relayer_address: c.relayer_address,
      merged_blocks_url: c.merged_blocks_url,
      state_store_url: c.substreams_state_store_url,
    },

    firehose: {
      name: 'firehose-%s' % c.version_tag,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_storage_class: c.storage_class,
      },

      augmentedData: c.augmentedData,
      cache_recent_bytes: 7 * GiB,
      cache_age_bytes: 7 * GiB,
      client_jwt: '',
      client_endpoint: '127.0.0.1:9000',
      default_grpc_port: c.default_grpc_port,
      common_auth_plugin: c.common_auth_plugin,
      relayer_address: c.relayer_address,
      one_blocks_url: c.one_blocks_url,
      merged_blocks_url: c.merged_blocks_url,
      forked_blocks_url: c.forked_blocks_url,
      backendconfig_name: 'streamingfast-backendconfig',
      first_streamable_block: c.first_streamable_block,
      discoveryServiceURL: '',
      fqdn: c.fqdn,
      substream_enabled: false,
      state_store_url: c.substreams_state_store_url,
    },

    relayer: {
      name: 'relayer-%s' % c.version_tag,
      replicas: 2,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },

      augmentedData: c.augmentedData,
      default_grpc_port: c.default_grpc_port,
      reader_name: 'reader-bt-%s' % c.version_tag,
      reader_port: c.reader_bt.default_grpc_port,
      reader_addresses:
        (if std.get(c, 'reader_bt') != null then [
           'dns:///%s-0.%s:%d' % [self.reader_name, self.reader_name, self.reader_port],
           'dns:///%s-1.%s:%d' % [self.reader_name, self.reader_name, self.reader_port],
         ] else []),


      one_blocks_url: c.one_blocks_url,
      default_read_account: c.default_read_account,
    },

    reader_bt: {
      name: 'reader-bt-%s' % c.version_tag,
      replicas: 1,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_max: error 'resource.disk_max must be set',
        disk_storage_class: c.storage_class,
      },
      readiness_max_latency_seconds: c.node_readiness_max_latency_seconds,
      default_grpc_port: c.default_grpc_port,
      project_id: error 'project_id must be set (This is the bigtable project ID)',
      instance_id: error 'instance_id must be set (This is the bigtable instance ID)',
      merged_blocks_url: c.merged_blocks_url,
      one_blocks_url: c.one_blocks_url,
    },
  },
}
