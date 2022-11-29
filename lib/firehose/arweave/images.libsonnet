{
  _images+:: {
    default: self.get(self.release_tag),
    get(tag): '%s:%s' % [self.base, tag],

    base:: 'ghcr.io/streamingfast/firehose-arweave',
    release_tag:: 'v1.1.1',

    reader:: self.default,
    firehose:: self.default,
    merger:: self.default,
    relayer:: self.default,
  },
}
