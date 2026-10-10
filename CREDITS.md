# Credits

TomTom never published its watch protocol. TomTomSync relies on people who
reverse-engineered it and shared their work.

- **[TomTomWatch](https://github.com/scubajorgen/TomTomWatch)** (Java) by Jorgen van der Velde
  ([@scubajorgen](https://github.com/scubajorgen)), with contributions from Emanuele Corini,
  Derick Rethans and 42Bastian. TomTomSync started as a way to run it on a modern Mac.
  It is the main reference for the USB protocol, the watch file system, the settings
  file, the ttbin format (including heart rate recovery and step counts) and GPS QuickFix.
  TomTomWatch has no license. TomTomSync contains none of its code or files; it is a
  new Swift implementation of what TomTomWatch documents.
- **[ttwatch](https://github.com/ryanbinns/ttwatch)** (C, MIT license) by Ryan Binns:
  the first open source TomTom watch tool (2014), and a second reference for the
  protocol and ttbin format.
- **FIT**: TomTomSync has its own encoder, based on Garmin's public
  [FIT protocol](https://developer.garmin.com/fit/protocol/). The Garmin SDK is used
  only to validate output.

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
