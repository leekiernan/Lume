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

The router regression also serves these payloads with only the source timestamps
rebased to the current clock, so freshness does not make that test expire. Its
device TMDB client has a configured dummy token and a dedicated session that
fails the test on any request. Cast, logos, trailers and the proxy receipt must
still arrive for both movies and series. No per-title switch or `.env` edit is
needed, and the separate fallback tests continue to exercise proxy misses.
