# gpio2udp

Periodically broadcast GPIO values (of a Raspberry Pi, for example) via UDP.

## Usage

Build using `swift build`, then run
```
.build/debug/gpio2udp <options> [gpios ...]
Options:
  -d             print debug output
  -i <pin>       configure and use <pin> as an input pin
  -p <port>      broadcast to <port> instead of 12121
  -q             turn off all non-critical logging output
  -v             increase logging verbosity
```

### Example

Configure GPIO pin 7 as input and broadcast its status to the default port (12121) every 30 seconds:
```
gpio2udp -i7
```

Configure and broadcast GPIOs 4, 17, 22, and 27, to port 12345:
```
gpio2udp -p 12345 -i4 -i17 -i22 -i27
```
Same as above, but do not try to configure the given ports (they need to be set up correctly already):
```
gpio2udp -p 12345 4 17 22 27
```

## Prerequisites

 * **Linux**: the GPIO pins are accessed via `/sys/class/gpio`.
 * **Swift 3**: you need to have a working Swift compiler, including the Swift package manager.
 
## Cross-Compiling

Trying to compile on a Raspberry Pi (or other SBC) can be painfully slow.
You can now build Swift in an ARM docker container on Linux or macOS using the
[dockSwiftOnARM](https://github.com/helje5/dockSwiftOnARM) project.
Alternatively, you can build your own cross-compilation toolchain for the Swift Package Manager following
[these instructions](https://github.com/helje5/dockSwiftOnARM/blob/master/toolchain/README.md).
Then you should be able to cross-compile using something like:
```
swift build --destination /usr/local/cross/cross-toolchain/rpi-ubuntu-xenial-destination.json
```

## Troubleshooting

### Compiling for a Raspberry Pi Zero or Raspberry Pi 1

At the moment, there does not seem to be a Swift distribution for `armv6`-based SBCs.
There are instructions for downloading Swift 3.0.2 for the Pi 1
[here](https://www.uraimo.com/2016/12/30/Swift-3-0-2-for-raspberrypi-zero-1-2-3/),
but it comes without the Package Manager and I get linker errors when trying to
use this under Raspbian Jessie.

As a workaround, you can simply run the `main.swift` from the command line, e.g.:
```
sudo cp -p Sources/main.swift /usr/local/bin/gpio2udp.swift
sudo chmod +x /usr/local/bin/gpio2udp.swift
/usr/local/bin/gpio2udp.swift -i7
```
This works, but takes about a minute to start (compiling on the Pi 1 is *really* slow!).

### Running

**macOS**

Running under macOS or other non-Linux operating systems will *not work*
and will give you an error message like this:
```
$ gpio2udp -i7
Cannot open '/sys/class/gpio/export' for writing: No such file or directory
Cannot export GPIO 7: No such file or directory
Cannot open '/sys/class/gpio/gpio7/direction' for writing: No such file or directory
fatal error: Cannot configure GPIO 7 as input: No such file or directory: file /Users/rh/Dropbox/Developer/src/swift/gpio2udp/Sources/main.swift, line 105
Illegal instruction
```

**Permission denied**

If you get an error message like this
```
Cannot open '/sys/class/gpio/export' for writing: Permission denied
```
(followed by more `Permission denied` error messages),
this means that the user account you are logged in with is not allowed
to access the GPIOs. Depending on your distribution, you either need
to run as `root` (e.g. using `sudo`), or add your account to the `gpio` group.

**Unconfigured GPIO**

If you run the command without the `-i` flag for a GPIO pin, that pin already
Needs to be configured as an input.
Otherwise you will get an error message like:
```
fatal error: Cannot open '/sys/class/gpio/gpio4/value' for input: No such file or directory: file /home/user/src/swift/rh/gpio2udp/Sources/main.swift, line 82
Current stack trace:
0    libswiftCore.so                    0x00007f32e6e061c0 swift_reportError + 120
1    libswiftCore.so                    0x00007f32e6e20ad0 _swift_stdlib_reportFatalErrorInFile + 100
2    libswiftCore.so                    0x00007f32e6c1b40c <unavailable> + 1188876
3    libswiftCore.so                    0x00007f32e6db337d <unavailable> + 2859901
4    libswiftCore.so                    0x00007f32e6c1abe6 <unavailable> + 1186790
5    libswiftCore.so                    0x00007f32e6db9290 <unavailable> + 2884240
6    libswiftCore.so                    0x00007f32e6c1b01f <unavailable> + 1187871
7    libswiftCore.so                    0x00007f32e6d79fa9 <unavailable> + 2625449
8    libswiftCore.so                    0x00007f32e6c1abe6 <unavailable> + 1186790
9    libswiftCore.so                    0x00007f32e6d37260 specialized _assertionFailure(StaticString, String, file : StaticString, line : UInt, flags : UInt32) -> Never + 144
10   gpio2udp                           0x00000000004066be <unavailable> + 26302
11   gpio2udp                           0x000000000040443c <unavailable> + 17468
12   libc.so.6                          0x00007f32e4d78740 __libc_start_main + 240
13   gpio2udp                           0x0000000000403029 <unavailable> + 12329
Illegal instruction (core dumped)
```

## UDP Data Format

The format of the UDP data is a simple structure that posts (in network byte order)
the state of the UDP pins and a mask, as follows:
```
struct UDPData {
    let gpios: UInt64   ///< GPIO values
    let mask:  UInt64   ///< GPIO mask (0 = unused GPIO)
}
```
Each bit represents a GPIO (e.g. the value of GPIO 0 is stored in bit 0),
with the status of the GPIOs (`0` or `1` for each bit) stored in `gpios`
and the `mask` representing the GPIOs that contain valid information
(i.e., the corresponding bit in the mask is `1`).

