{
  _images+:: {
    firesol(tag): '%s:%s' % [self.base, tag],
    base:: 'ghcr.io/streamingfast/firehose-solana',
    tag: '301eac3',

    substreams:: self.firesol(self.tag),
    firehose:: self.firesol(self.tag),
    merger:: self.firesol(self.tag),
    relayer:: self.firesol(self.tag),
    reader_bt:: self.firesol(self.tag),
  },
}
