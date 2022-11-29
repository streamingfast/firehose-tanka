{
  _images+:: {
    build: '%s:%s' % [self.base, self.build_tag],
    getBuild(tag): '%s:%s' % [self.base, tag],
    base:: 'ghcr.io/streamingfast/firehose-aptos',
    build_tag:: error '_images.build_tag must be set',

    reader:: self.build,
    firehose:: self.build,
    merger:: self.build,
    relayer:: self.build,
  },
}
