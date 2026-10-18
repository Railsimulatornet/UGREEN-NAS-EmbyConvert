# EmbyConvert for UGREEN DXP NAS (Intel QSV)

[![Quality](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/quality.yml)
[![CodeQL](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/UGREEN-NAS-EmbyConvert/actions/workflows/codeql.yml)

English documentation is provided in the `en/` folder.

- Manual (EN): `en/EmbyConvert_Manual_EN_v1.1.pdf`
- Package (EN): `en/EmbyConvert/` and `en/Screens/`

## Output validation

With `VERIFY_OUTPUT=1`, every output video and audio stream is fully decoded
before the temporary file is promoted. Decoder errors or a primary-video duration mismatch
reject the new output and preserve any existing destination file. Duration
tolerance is 1%, with a minimum of 0.25 seconds and a maximum of 2 seconds for
timestamp and packet rounding. The comparison uses the presentation-timestamp
span of `v:0`, including the final packet duration. Longer excluded audio tracks
and shifted start timestamps do not affect it; missing MKV container/stream
duration metadata is also supported. Video spans that cannot be determined
reliably are rejected. Full decoding requires additional CPU time.
Source media remains mounted read-only in the Compose package.

The regression tests use only synthetic clips and a stubbed encoder:
`python3 -m unittest discover -s tests -v`.
