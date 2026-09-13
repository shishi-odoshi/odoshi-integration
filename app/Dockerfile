# Environment for the GENERATED Rails app. The app itself is created fresh at
# container start (see entrypoint.sh) from otp-rails-template's template.rb —
# mirroring the template repo's no-drift philosophy. This image only prepares
# the toolchain and pre-warms the gems the generated app will resolve, so the
# runtime `bundle install` is fast.
FROM ruby:3.4

RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq-dev postgresql-client procps curl git && \
    rm -rf /var/lib/apt/lists/*

ENV BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    LANG=C.UTF-8

# rails for `rails new`; the rest pre-warms the generated app's dependency set.
# json is pinned < 3.0 by the template (json 3.x breaks Rails 8.1's
# ActiveSupport::JSON.decode); pre-install a 2.x so bundler finds it warm.
RUN gem install rails --no-document && \
    gem install pg puma bootsnap propshaft importmap-rails turbo-rails \
                stimulus-rails jbuilder solid_queue solid_cable solid_cache \
                thruster otp-rails --no-document && \
    gem install json --version "< 3.0" --no-document

WORKDIR /work

CMD ["/harness/entrypoint.sh"]
