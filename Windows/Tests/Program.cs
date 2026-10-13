using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using YandexDiskDownloader.Core;

var passed = 0;
var tests = new List<(string, Func<Task>)>();
void Add(string name, Func<Task> test) => tests.Add((name, test));
void Check(bool condition) { if (!condition) throw new Exception("Assertion failed"); }
async Task Throws<T>(Func<Task> action) where T : Exception
{ try { await action(); } catch (T) { return; } throw new Exception("Expected " + typeof(T).Name); }
RemoteFile FileOf(byte[] bytes, string name = "track.mp3") => new("/" + name, ["folder", name], bytes.Length, null, Convert.ToHexString(SHA256.HashData(bytes)));
Resource FileResource(string name, string? path = null) => new(name, "file", path, 10, null, null, null);
Resource Folder(Resource[] items, int total, int offset = 0) => new("Root", "dir", "/", null, null, null, new(items, total, offset, 2));
HttpResponseMessage Response(HttpStatusCode code, byte[] bytes) => new(code) { Content = new ByteArrayContent(bytes) };
var payload = Encoding.UTF8.GetBytes("1234567");

Add("public links and spoofed hosts", async () =>
{
    Check(PublicLink.Validate(" https://disk.yandex.ru/d/test#x ") == "https://disk.yandex.ru/d/test");
    foreach (var bad in new[] { "http://disk.yandex.ru/d/x", "https://disk.yandex.ru.evil.com/d/x", "https://user@disk.yandex.ru/d/x", "https://disk.yandex.ru:80/d/x", "https://disk.yandex.ru/d/", "file:///tmp/x" })
        await Throws<InvalidDataException>(() => Task.FromResult(PublicLink.Validate(bad)));
});
Add("Windows reserved and invalid names", () =>
{
    Check(SafeNames.Local("CON.mp3") == "_CON.mp3"); Check(SafeNames.Local("LPT9") == "_LPT9");
    Check(SafeNames.Local("a:b?c\\d. ") == "a_b_c_d"); Check(SafeNames.Local(new string('a', 400) + ".mp3").Length < 180);
    return Task.CompletedTask;
});
Add("traversal rejection and Unicode collisions", async () =>
{
    await Throws<InvalidDataException>(() => Task.FromResult(SafeNames.Local("..")));
    await Throws<InvalidDataException>(() => Task.FromResult(SafeNames.Local("a/b")));
    await Throws<InvalidDataException>(() => { SafeNames.ValidateApiPath("/a/../b"); return Task.CompletedTask; });
    var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    Check(SafeNames.Reserve(SafeNames.Local("é.mp3"), used) != SafeNames.Reserve(SafeNames.Local("e\u0301.mp3"), used));
});
Add("recursive pagination and API paths", async () =>
{
    var mock = new Resources((path, offset) => path switch
    {
        null when offset == 0 => Folder([FileResource("one.mp3", "/prefix/one.mp3"), new("sub", "dir", "/prefix/sub", null, null, null, null)], 3),
        null => Folder([FileResource("last.mp3")], 3, 2),
        "/prefix/sub" => Folder([FileResource("inner.mp3", "/prefix/sub/inner.mp3")], 1),
        _ => throw new Exception("Unexpected API path")
    });
    var manifest = await new FolderScanner(mock, 2).Scan("key", null, default);
    Check(manifest.Files.Count == 3 && manifest.Directories.Count == 2);
    Check(manifest.Files[0].ApiPath == "/prefix/one.mp3");
});
Add("single public file", async () =>
{
    var result = await new FolderScanner(new Resources((_, _) => FileResource("a.mp3"))).Scan("key", null, default);
    Check(result.Files.Count == 1 && result.Files[0].ApiPath == null);
});
Add("missing nested folder is skipped", async () =>
{
    var mock = new Resources((path, _) => path == null ? Folder([new("missing", "dir", "/missing", null, null, null, null), FileResource("ok")], 2) : throw new HttpStatusException(404));
    var result = await new FolderScanner(mock).Scan("key", null, default);
    Check(result.Files.Count == 1 && result.Warnings.Count == 1);
});
Add("incomplete pagination fails explicitly", async () =>
{
    var mock = new Resources((_, offset) => offset == 0 ? Folder([FileResource("one")], 2) : Folder([], 2, offset));
    await Throws<InvalidDataException>(() => new FolderScanner(mock, 1).Scan("key", null, default));
});
Add("API query encoding and no file retries", async () =>
{
    var requests = 0;
    using var client = new HttpClient(new Handler((request, _) =>
    {
        requests++; Check(request.RequestUri!.Query.Contains("path=%2Fname%20with%20space"));
        return Task.FromResult(Response(HttpStatusCode.Forbidden, []));
    }));
    await Throws<HttpStatusException>(() => new DiskApi(client).DownloadUrl("key", "/name with space", default));
    Check(requests == 1);
});
Add("metadata retry on transient response", async () =>
{
    var requests = 0;
    using var client = new HttpClient(new Handler((_, _) =>
    {
        requests++;
        return Task.FromResult(requests == 1 ? Response(HttpStatusCode.ServiceUnavailable, []) :
            Response(HttpStatusCode.OK, Encoding.UTF8.GetBytes("{\"name\":\"one\",\"type\":\"file\",\"size\":7}")));
    }));
    var result = await new DiskApi(client).Resource("key", null, 0, 100, default);
    Check(result.Size == 7 && requests == 2);
});
Add("streamed bytes and checksum", async () =>
{
    using var client = new HttpClient(new Handler((_, _) => Task.FromResult(Response(HttpStatusCode.OK, payload))));
    using var partial = new PartialTransfer(); long progress = 0;
    await new FileTransfer(client).Download(new("https://example.com/file"), FileOf(payload), partial, value => progress = value, default);
    await FileTransfer.Verify(partial.Stream, FileOf(payload), true, default); Check(progress == payload.Length);
});
Add("partial range resume", async () =>
{
    using var client = new HttpClient(new Handler((request, _) =>
    {
        Check(request.Headers.Range?.Ranges.Single().From == 3);
        var response = Response(HttpStatusCode.PartialContent, payload[3..]);
        response.Content.Headers.ContentRange = new ContentRangeHeaderValue(3, 6, 7);
        return Task.FromResult(response);
    }));
    using var partial = new PartialTransfer(); await partial.Stream.WriteAsync(payload.AsMemory(0, 3));
    await new FileTransfer(client).Download(new("https://example.com/file"), FileOf(payload), partial, _ => { }, default);
    await FileTransfer.Verify(partial.Stream, FileOf(payload), true, default);
});
Add("range ignored restarts cleanly", async () =>
{
    using var client = new HttpClient(new Handler((_, _) => Task.FromResult(Response(HttpStatusCode.OK, payload))));
    using var partial = new PartialTransfer(); await partial.Stream.WriteAsync(payload.AsMemory(0, 3));
    await new FileTransfer(client).Download(new("https://example.com/file"), FileOf(payload), partial, _ => { }, default);
    await FileTransfer.Verify(partial.Stream, FileOf(payload), true, default);
});
Add("invalid resume range rejected", async () =>
{
    using var client = new HttpClient(new Handler((_, _) =>
    {
        var response = Response(HttpStatusCode.PartialContent, payload[3..]); response.Content.Headers.ContentRange = new(2, 5, 7); return Task.FromResult(response);
    }));
    using var partial = new PartialTransfer(); await partial.Stream.WriteAsync(payload.AsMemory(0, 3));
    await Throws<InvalidDataException>(() => new FileTransfer(client).Download(new("https://example.com/file"), FileOf(payload), partial, _ => { }, default));
});
Add("HTTPS downgrade rejected", async () =>
{
    using var client = new HttpClient(new Handler((_, _) =>
    {
        var response = Response(HttpStatusCode.Found, []); response.Headers.Location = new("http://example.com/file"); return Task.FromResult(response);
    }));
    using var partial = new PartialTransfer();
    await Throws<InvalidDataException>(() => new FileTransfer(client).Download(new("https://example.com/file"), FileOf(payload), partial, _ => { }, default));
});
Add("stalled network watchdog", async () =>
{
    using var client = new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new StallingStream()) })));
    using var partial = new PartialTransfer();
    await Throws<OperationCanceledException>(() => new FileTransfer(client, TimeSpan.FromMilliseconds(100)).Download(new("https://example.com/file"), FileOf(payload), partial, _ => { }, default));
});
Add("size and hash failures", async () =>
{
    await Throws<InvalidDataException>(() => FileTransfer.Verify(new MemoryStream(payload[..3]), FileOf(payload), true, default));
    await Throws<InvalidDataException>(() => FileTransfer.Verify(new MemoryStream(Encoding.UTF8.GetBytes("xxxxxxx")), FileOf(payload), true, default));
});
Add("safe publication and existing-file verification", async () =>
{
    var temp = Path.Combine(Path.GetTempPath(), "YandexDisk-Test-" + Guid.NewGuid()); Directory.CreateDirectory(temp);
    try
    {
        var destination = new SafeDestination(temp); var file = FileOf(payload);
        destination.CreateFolder(["folder"]);
        var original = await destination.Publish(file, new MemoryStream(payload), default);
        var second = await destination.Publish(file, new MemoryStream(Encoding.UTF8.GetBytes("changed")), default);
        Check(original != second && (await File.ReadAllBytesAsync(original)).SequenceEqual(payload));
        Check(await destination.Matches(file, true, default));
        await File.WriteAllTextAsync(original, "xxxxxxx"); Check(!await destination.Matches(file, true, default));
        await Throws<InvalidDataException>(() => Task.FromResult(destination.FullPath(["..", "escape"])));
    }
    finally { Directory.Delete(temp, true); }
});
Add("temporary handle cleanup and cancellation", async () =>
{
    string path; using (var partial = new PartialTransfer()) { path = partial.Stream.Name; Check(File.Exists(path)); }
    Check(!File.Exists(path));
    using var token = new CancellationTokenSource(); token.Cancel();
    using var client = new HttpClient(new Handler((_, ct) => { ct.ThrowIfCancellationRequested(); return Task.FromResult(Response(HttpStatusCode.OK, payload)); }));
    using var buffer = new PartialTransfer();
    await Throws<OperationCanceledException>(() => new FileTransfer(client).Download(new("https://example.com/file"), FileOf(payload), buffer, _ => { }, token.Token));
});

foreach (var (name, test) in tests)
{
    try { await test(); Console.WriteLine("PASS " + name); passed++; }
    catch (Exception error) { Console.Error.WriteLine("FAIL " + name + ": " + error); Environment.ExitCode = 1; }
}
Console.WriteLine($"{passed}/{tests.Count} tests passed");

sealed class Resources(Func<string?, int, Resource> get) : IResources
{
    public Task<Resource> Resource(string key, string? path, int offset, int limit, CancellationToken token)
    { token.ThrowIfCancellationRequested(); return Task.FromResult(get(path, offset)); }
}
sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
}
sealed class StallingStream : Stream
{
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) { await Task.Delay(Timeout.Infinite, token); return 0; }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) => ReadAsync(buffer.AsMemory(offset, count), token).AsTask();
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override void Flush() => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
