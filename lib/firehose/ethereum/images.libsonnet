{
  _images+:: {
    local img = self,

    latest_release_geth: img.fireeth('v1.2.0-geth-v1.10.25-fh2.1'),
    latest_release: img.fireeth('v1.2.2'),
    latest_dev: img.fireeth('476d5bb'),
    latest_stable: img.fireeth('9f1bc60'),
    latest_evm_executor: img.evmExecutor('753fef7'),

    fireeth(tag): '%s:%s' % [img.base, tag],
    evmExecutor(tag):: '%s:%s' % [self.base_evm_executor, tag],
    consensusImage(version, tag_suffix='-amd64-modern'):: 'sigp/lighthouse:%s%s' % [version, tag_suffix],

    base:: 'ghcr.io/streamingfast/firehose-ethereum',
    base_evm_executor:: 'gcr.io/eoscanada-shared-services/evm-executor',

    evm_executor:: self.latest_evm_executor,
    consensus: self.consensusImage('v3.2.1'),
    firehose:: self.latest_release,
    merger:: self.latest_release,
    relayer:: self.latest_release,
    combined_index_builder:: self.latest_release,
    reader:: self.latest_release_geth,
    substreams:: self.latest_release,

  },
}
