import Foundation
#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

let args = CommandLine.arguments
let cmd = args[0]                   ///< command name
var verbosity = 1                   ///< verbosity level
var port = 12121                    ///< UDP broadcast port
var gpios = Array<Int>()            ///< GPIO pins to use
var input_gpios: UInt64 = 0         ///< input GPIO pins
var gpio_values: UInt64 = 0         ///< bit values of the GPIO pins (1 == high)
var fds: [CInt] = (0..<64).map { _ in -1 }  ///< GPIO file descriptors

var longopts: [option] = [
    option(name: "debug",           has_arg: 0, flag: nil, val: Int32("d".utf16.first!)),
    option(name: "input",           has_arg: 1, flag: nil, val: Int32("i".utf16.first!)),
    option(name: "port",            has_arg: 1, flag: nil, val: Int32("o".utf16.first!)),
    option(name: "quiet",           has_arg: 0, flag: nil, val: Int32("q".utf16.first!)),
    option(name: "verbose",         has_arg: 0, flag: nil, val: Int32("v".utf16.first!)),
]

fileprivate func usage() -> Never {
    print("Usage: \(cmd) <options> [gpios ...]")
    print("Options:")
    print("  -d, --debug                print debug output")
    print("  -i, --input=<pin>          configure and use <pin> as an input pin")
    print("  -p, --port=<port>          broadcast to <port> instead of \(port)")
    print("  -q, --quiet                turn off all non-critical logging output")
    print("  -v, --verbose              increase logging verbosity")
    exit(EXIT_FAILURE)
}


/// Wrapper around getopt() / getopt_long_only() for Swift
///
/// - Parameters:
///   - options: String containing the option characters
///   - long: optional address of a `struct option` table for long options
///   - index: optional index for long option continuation
/// - Returns: the next option character, '?' in case of an error, `nil` if finished
func get(options: String, long: UnsafePointer<option>? = nil, index: UnsafeMutablePointer<CInt>? = nil) -> Character? {
    let argc = CommandLine.argc
    let argv = CommandLine.unsafeArgv
    let ch: CInt
    if long != nil {
        ch = getopt_long_only(argc, argv, options, long, index)
    } else {
        ch = getopt(argc, argv, options)
    }
    guard ch != -1, let u = UnicodeScalar(UInt32(ch)) else { return nil }
    let c = Character(u)
    return c
}

/// Set up a pin as a GPIO pin with the given direction
///
/// - Parameters:
///   - pin: GPIO pin number to set up
///   - mode: "in" for input (default), "out" for output
/// - Throws: in case the `/sys/class/gpio` sysfs entry for the given pin does not exist
func set(pin: Int, mode: String = "in") throws {
    try "\(pin)".write(toFile: "/sys/class/gpio/export", atomically: false, encoding: .utf8)
    try mode.write(toFile: "/sys/class/gpio/gpio\(pin)/direction", atomically: false, encoding: .utf8)
}

/// Get a GPIO pin value
///
/// - Parameter pin: GPIO pin to read
/// - Returns: `false` if low or `true` if high, `nil` in case of a read error
/// - Throws: in case the `/sys/class/gpio` sysfs entry for the given pin does not exist
func get(pin: Int) -> Bool? {
    let filename = "/sys/class/gpio/gpio\(pin)/value"
    if fds[pin] < 0 {
        fds[pin] = open(filename, O_RDONLY)
        guard fds[pin] >= 0 else {
            fatalError("Cannot open '\(filename)' for input: \(String(cString: strerror(errno)))")
        }
    }
    let fd = fds[pin]
    var value = UInt8(0)
    if lseek(fd, 0, SEEK_SET) < 0 { perror("lseek on \(filename)") }
    return withUnsafeMutableBytes(of: &value) {
        guard read(fd, $0.baseAddress, 1) == 1 else {
            perror(filename)
            return nil
        }
        return (value & 1) != 0
    }
}

//
// Parse arguments
//
while let option = get(options: "di:o:p:qv") {
    switch option {
    case "d": verbosity = 9
    case "i": if let gpio  = Int(String(cString: optarg)), gpio >= 0 && gpio < 64 {
        do {
            try set(pin: gpio, mode: "in")
        } catch {
            fatalError("Cannot configure GPIO \(gpio) as input: \(String(cString: strerror(errno)))")
        }
        input_gpios |= 1 << UInt64(gpio)
        gpios.append(gpio)
    } else { usage() }
    case "p": if let p = Int(String(cString: optarg)) {
        port = p
    } else { usage() }
    case "q": verbosity  = 0
    case "v": verbosity += 1
    default: usage()
    }
}

let oi = Int(optind)
if oi < args.count {
    input_gpios = 0
    gpios = args[oi..<args.count].map {
        guard let gpio = Int($0) else { usage() }
        input_gpios |= 1 << UInt64(gpio)
        return gpio
    }
}

if input_gpios == 0 {
    fputs("*** At least one GPIO needs to be specified!\n", stderr)
    usage()
}

//
// Network data and functions
//
struct UDPData {
    let gpios: UInt64   ///< GPIO values
    let mask: UInt64    ///< GPIO mask (0 = unused GPIO)
}

let bigEndian = 1.bigEndian == 1    // true if host is big endian
let littleEndian = !bigEndian       // true if host is little endian

func htons(_ port: in_port_t) -> in_port_t { return bigEndian ? port : port.bigEndian }
func htonl(_ addr: in_addr_t) -> in_addr_t { return bigEndian ? addr : addr.bigEndian }
func htonll(_ value: UInt64) -> UInt64 { return bigEndian ? value : value.bigEndian }

var sock: CInt = -1
var addr = UnsafeMutablePointer<sockaddr_in>.allocate(capacity: 1)
func broadcast(data: UDPData) {
    var packet = data
    let sin = UnsafeMutableRawPointer(addr)
    let asize = MemoryLayout<sockaddr_in>.size
    if sock < 0 {
        sock = socket(PF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { fatalError("Cannot create UDP socket: \(String(cString: strerror(errno)))") }
        var yes: CInt = 1
        withUnsafeBytes(of: &yes) {
            let yes = $0.baseAddress
            if setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, yes, socklen_t(MemoryLayout<CInt>.size)) == -1 {
                perror("Cannot set SO_REUSEADDR")
            }
            if setsockopt(sock, SOL_SOCKET, SO_BROADCAST, yes, socklen_t(MemoryLayout<CInt>.size)) == -1 {
                perror("Cannot set SO_BROADCAST")
            }
        }
        memset(sin, 0, asize)
        addr.pointee.sin_family = sa_family_t(AF_INET)
        addr.pointee.sin_port = htons(in_port_t(port))
        addr.pointee.sin_addr.s_addr = htonl(INADDR_BROADCAST)
    }
    withUnsafeBytes(of: &packet) {
        if sendto(sock, $0.baseAddress, $0.count, 0, sin.assumingMemoryBound(to: sockaddr.self), socklen_t(asize)) == -1 {
            perror("Cannot send to socket \(sock) on port \(port)")
        }
    }
}

var keepRunning = true
func trigger_exit(signal: CInt) -> Void {
    keepRunning = false
}

signal(SIGTERM, trigger_exit)
signal(SIGQUIT, trigger_exit)
signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)

//
// Periodically send GPIO values
//
var i = 0
while keepRunning {
    let old = gpio_values
    for gpio in gpios {
        guard let high = get(pin: gpio) else { continue }
        let value = 1 << UInt64(gpio)
        if high { gpio_values |=  value }
        else    { gpio_values &= ~value }
        if verbosity >= 9 {
            print("GPIO \(gpio) is \(high ? "high" : "low")")
        }
    }
    if i == 0 || gpio_values != old {
        if verbosity > 1 {
            print("Transmitting \(gpio_values) with mask \(input_gpios)")
        }
        broadcast(data: UDPData(gpios: htonll(gpio_values), mask: htonll(input_gpios)))
    }
    i += 1
    if i >= 30 { i = 0 }    // transmit every 30 seconds
    sleep(1)
}

fds.filter { $0 >= 0 }.forEach { close($0) }

shutdown(sock, SHUT_RDWR)
close(sock)
