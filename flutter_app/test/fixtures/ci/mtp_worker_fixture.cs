using System;
using System.IO;
using System.Text;
using System.Threading;

public static class MtpWorkerFixture {
    public static int Main(string[] args) {
        var self = System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName;
        if (Path.GetFileNameWithoutExtension(self) == "isolated-worker") {
            var directory = Path.GetDirectoryName(self);
            if (!String.Equals(Environment.CurrentDirectory, directory, StringComparison.OrdinalIgnoreCase)) return 17;
            var windows = Environment.GetEnvironmentVariable("WINDIR");
            foreach (var search in Environment.GetEnvironmentVariable("PATH").Split(';')) {
                if (!String.Equals(search, directory, StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(search, windows, StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(search, Path.Combine(windows, "System32"), StringComparison.OrdinalIgnoreCase)) return 18;
            }
        }
        if (Path.GetFileNameWithoutExtension(self) == "lipo") {
            File.AppendAllText(Environment.GetEnvironmentVariable("NSO_LIPO_CALLS"),
                String.Join(" ", args) + "\n");
            if (Environment.GetEnvironmentVariable("NSO_LIPO_FAIL") == "1") return 15;
            if (args[0] == "-archs") {
                Console.WriteLine("x86_64 arm64");
                return 0;
            }
            if (args.Length != 5 || args[0] != "-create" || args[3] != "-output" ||
                    !File.Exists(args[1]) || !File.Exists(args[2])) return 16;
            var combined = new byte[256];
            combined[0] = 0xca; combined[1] = 0xfe; combined[2] = 0xba; combined[3] = 0xbe;
            File.WriteAllBytes(args[4], combined);
            return 0;
        }
        if (Path.GetFileNameWithoutExtension(self) == "dart") {
            if (!File.Exists(Environment.GetEnvironmentVariable("NSO_CARGOKIT_SENTINEL"))) return 13;
            File.AppendAllText(Environment.GetEnvironmentVariable("NSO_DART_CALLS"),
                String.Join(" ", args) + "\n");
            for (var index = 0; index + 1 < args.Length; index++) {
                if (args[index] != "--output") continue;
                Directory.CreateDirectory(Path.GetDirectoryName(args[index + 1]));
                File.Copy(self, args[index + 1], true);
                return 0;
            }
            return 14;
        }
        var cargo = Environment.GetEnvironmentVariable("NSO_CARGO_JSON");
        if (Path.GetFileNameWithoutExtension(
                System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName) == "cargo") {
            File.AppendAllText(Environment.GetEnvironmentVariable("NSO_CARGO_CALLS"),
                String.Join(" ", args) + "\n");
            var command = String.Join(" ", args);
            if (command.Contains("aarch64-apple-darwin")) cargo =
                Environment.GetEnvironmentVariable("NSO_CARGO_JSON_ARM64") ?? cargo;
            if (command.Contains("x86_64-apple-darwin")) cargo =
                Environment.GetEnvironmentVariable("NSO_CARGO_JSON_X64") ?? cargo;
            Console.Write(File.ReadAllText(cargo));
            return Environment.GetEnvironmentVariable("NSO_CARGO_FAIL") == "1" ? 7 : 0;
        }
        var behavior = Path.GetFileNameWithoutExtension(
            System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName).StartsWith("hang")
            ? "hang" : Path.GetFileNameWithoutExtension(self).StartsWith("fragmented")
            ? "fragmented" : Environment.GetEnvironmentVariable("NSO_MTP_FIXTURE_BEHAVIOR") ?? "ok";
        if (behavior == "hang") {
            Thread.Sleep(60000);
            return 0;
        }
        var input = Console.OpenStandardInput();
        var header = new byte[4];
        if (input.Read(header, 0, 4) != 4) return 9;
        var length = (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
        if (length < 16 || length > 65552) return 10;
        var bytes = new byte[length];
        var read = 0;
        while (read < length) {
            var count = input.Read(bytes, read, length - read);
            if (count <= 0) return 11;
            read += count;
        }
        if (Encoding.ASCII.GetString(bytes, 0, 8) != "NSOMTP2\0" ||
                ReadInt(bytes, 8) != length - 16 || ReadInt(bytes, 12) != 0 ||
                Encoding.UTF8.GetString(bytes, 16, length - 16) != "{\"method\":\"close\"}" ||
                args.Length != 0) return 12;
        var output = Console.OpenStandardOutput();
        if (behavior == "oversized") {
            output.Write(new byte[] { 0, 1, 0, 17 }, 0, 4);
            return 0;
        }
        var response = behavior == "bad"
            ? "{\"value\":{\"Ok\":1},\"payload_length\":0}"
            : "{\"value\":{\"Ok\":null},\"payload_length\":0}";
        if (behavior == "legacy") response = "{\"value\":{\"Ok\":null}}";
        if (behavior == "payload") response = "{\"value\":{\"Ok\":null},\"payload_length\":1}";
        bytes = Encoding.UTF8.GetBytes(response);
        var binary = behavior != "legacy";
        length = bytes.Length + (binary ? 16 : 0) + (behavior == "payload" ? 1 : 0);
        output.Write(new byte[] {
            (byte)(length >> 24), (byte)(length >> 16), (byte)(length >> 8), (byte)length
        }, 0, 4);
        if (binary) {
            var magic = Encoding.ASCII.GetBytes(behavior == "wrong-magic" ? "NSOMTP1\0" : "NSOMTP2\0");
            output.Write(magic, 0, magic.Length);
            var headerLength = bytes.Length + (behavior == "length-mismatch" ? 1 : 0);
            output.Write(new byte[] {
                (byte)(headerLength >> 24), (byte)(headerLength >> 16),
                (byte)(headerLength >> 8), (byte)headerLength
            }, 0, 4);
            output.Write(new byte[] { 0, 0, 0, (byte)(behavior == "payload" ? 1 : 0) }, 0, 4);
        }
        if (behavior == "truncated") {
            output.Write(bytes, 0, bytes.Length - 1);
        } else if (behavior == "fragmented") {
            foreach (var item in bytes) { output.WriteByte(item); output.Flush(); }
        } else {
            output.Write(bytes, 0, bytes.Length);
        }
        if (behavior == "payload" || behavior == "trailing") output.WriteByte(1);
        output.Flush();
        return behavior == "exit-error" ? 8 : 0;
    }
    private static int ReadInt(byte[] bytes, int offset) {
        return (bytes[offset] << 24) | (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) | bytes[offset + 3];
    }
}
