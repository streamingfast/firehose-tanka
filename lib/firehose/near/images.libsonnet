{
  _images+:: {
    build: '%s:%s' % [self.base, self.build_tag],
    getBuild(tag): '%s:%s' % [self.base, tag],
    getFireBuild(tag): '%s:%s' % [self.firebase, tag],

    base:: 'gcr.io/eoscanada-shared-services/sf-near',
    firebase:: 'ghcr.io/streamingfast/firehose-near',

    build_tag:: error '_images.build_tag must be set',
    bundle_tag:: error '_images.bundle_tag must be set',



    archive:: self.getFireBuild(self.bundle_tag),
    extractor:: self.getFireBuild(self.bundle_tag),

    firehose:: self.getFireBuild(self.build_tag),
    merger:: self.getFireBuild(self.build_tag),
    relayer:: self.getFireBuild(self.build_tag),
    receipt_index_builder:: self.getFireBuild(self.build_tag),
  },
}
