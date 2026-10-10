# Proxy metadata contract fixtures

Copied unchanged from the proxy's `testdata/lume-metadata-batch-{movie,series}.json`
at contract commit `01234ea`. Real TMDB responses for The Matrix, Your Name. and
Attack on Titan pass through the proxy's payload serializer. Each fixture also
contains `not_found` and `pending` items; there are no credentials.

`LumeProxySharedFixtureTests` feeds these bytes through the production capability
and batch reader, using a fixed clock so the source stamps never age the test
out. When the proxy contract changes, copy both fixtures again and run the app
tests alongside the proxy's contract tests. Do not hand-edit the JSON to make
the app decoder pass.
