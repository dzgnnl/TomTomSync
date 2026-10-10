# Credits

TomTom never published the USB protocol or file formats of its sports watches.
Everything TomTomSync knows about them comes from people who worked it out
themselves and shared the results. Thank you.

## TomTomWatch (Java)

- **Author:** Jorgen van der Velde ([@scubajorgen](https://github.com/scubajorgen)),
  with contributions from Emanuele Corini, Derick Rethans and 42Bastian
- **Source:** <https://github.com/scubajorgen/TomTomWatch>
- **Homepage:** <http://blog.studioblueplanet.net/?page_id=566>

TomTomSync started as an attempt to get TomTomWatch running on a current Mac,
and its design comes directly from that project. TomTomWatch was the main
reference for:

- the USB HID packet format, message types and the watch's startup sequence
- the watch file system: file IDs, listing, reading, writing and deleting files
- the settings manifest (file `0x00850000`) and the UTC offset setting
- the ttbin activity format and its record types, including heart rate recovery
  and the per-second step count used for running cadence
- the GPS QuickFix download URLs and update procedure

TomTomWatch does not declare a license. TomTomSync contains none of its source
code or data files: it is a new implementation in Swift, based on the protocol
and format knowledge that TomTomWatch documents.

## ttwatch (C, Linux)

- **Author:** Ryan Binns ([@ryanbinns](https://github.com/ryanbinns))
- **Source:** <https://github.com/ryanbinns/ttwatch>
- **License:** MIT (below)

ttwatch (2014) was the first open source tool for the TomTom GPS watches.
TomTomSync used it as a second reference for the protocol and the ttbin format.

## FIT

FIT files are written with TomTomSync's own small encoder, based on Garmin's
public [FIT protocol documentation](https://developer.garmin.com/fit/protocol/).
The Garmin FIT SDK is only used during development, to check the output, and
is not part of TomTomSync.

---

### ttwatch license

```
The MIT License (MIT)

Copyright (c) 2014 Ryan Binns

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

```
