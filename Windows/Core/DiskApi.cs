using System.Net;
using System.Text.Json;

namespace YandexDiskDownloader.Core;

public interface IResources
{
    Task<Resource> Resource(string key, string? path, int offset, int limit, CancellationToken token);
}

public sealed class DiskApi(HttpClient client) : IResources
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private DateTimeOffset nextRequest = DateTimeOffset.MinValue;
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    public static HttpClient CreateClient()
    {
        var result = new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false, ConnectTimeout = TimeSpan.FromSeconds(30) });
        result.Timeout = Timeout.InfiniteTimeSpan;
        result.DefaultRequestHeaders.UserAgent.ParseAdd("YandexDiskDownloader-Windows/1.0.1");
        return result;
    }
    public async Task Cooldown(TimeSpan delay)
    {
        await gate.WaitAsync();
        try { var until = DateTimeOffset.UtcNow + delay; if (until > nextRequest) nextRequest = until; }
        finally { gate.Release(); }
    }
    private async Task Throttle(CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            var delay = nextRequest - DateTimeOffset.UtcNow;
            if (delay > TimeSpan.Zero) await Task.Delay(delay, token);
            nextRequest = DateTimeOffset.UtcNow + TimeSpan.FromMilliseconds(150);
        }
        finally { gate.Release(); }
    }
    public Task<Resource> Resource(string key, string? path, int offset, int limit, CancellationToken token) =>
        Request<Resource>("resources", key, path, $"&offset={offset}&limit={limit}&sort=name", true, token);
    public async Task<Uri> DownloadUrl(string key, string? path, CancellationToken token)
    {
        var link = await Request<DownloadLink>("resources/download", key, path, "", false, token);
        if (!Uri.TryCreate(link.Href, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            !string.IsNullOrEmpty(uri.UserInfo) || link.Method is not (null or "GET") || link.Templated == true)
            throw new InvalidDataException("Некорректный адрес загрузки.");
        return uri;
    }
    private async Task<T> Request<T>(string endpoint, string key, string? path, string extra, bool retry, CancellationToken token)
    {
        if (path != null) SafeNames.ValidateApiPath(path);
        var uri = $"https://cloud-api.yandex.net/v1/disk/public/{endpoint}?public_key={Uri.EscapeDataString(key)}{extra}" +
            (path == null ? "" : "&path=" + Uri.EscapeDataString(path));
        for (var attempt = 0; ; attempt++)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                await Throttle(token);
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
                deadline.CancelAfter(TimeSpan.FromSeconds(40));
                using var response = await client.GetAsync(uri, deadline.Token);
                if (!response.IsSuccessStatusCode)
                {
                    var wait = RetryAfter(response);
                    if ((int)response.StatusCode == 429) await Cooldown(wait ?? TimeSpan.FromSeconds(2));
                    throw new HttpStatusException((int)response.StatusCode, wait);
                }
                var bytes = await response.Content.ReadAsByteArrayAsync(deadline.Token);
                return JsonSerializer.Deserialize<T>(bytes, Json) ?? throw new InvalidDataException("Пустой ответ API.");
            }
            catch (Exception e) when (retry && attempt < 3 && !token.IsCancellationRequested && Transient(e))
            {
                var delay = e is HttpStatusException { RetryAfter: { } wait } ? wait : TimeSpan.FromSeconds(Math.Pow(2, attempt));
                await Cooldown(delay);
            }
        }
    }
    public static bool Transient(Exception e) => e is HttpRequestException or OperationCanceledException ||
        e is HttpStatusException { Status: 408 or 429 or >= 500 and <= 599 };
    public static TimeSpan? RetryAfter(HttpResponseMessage response)
    {
        var retry = response.Headers.RetryAfter;
        var wait = retry?.Delta ?? (retry?.Date is { } date ? date - DateTimeOffset.UtcNow : null);
        return wait is { } value ? TimeSpan.FromSeconds(Math.Clamp(value.TotalSeconds, 0, 300)) : null;
    }
}

public sealed class FolderScanner(IResources api, int pageSize = 100)
{
    public async Task<Manifest> Scan(string key, Action<int>? progress, CancellationToken token)
    {
        var root = await api.Resource(key, null, 0, pageSize, token);
        var rootName = SafeNames.Local(root.Name);
        var result = new Manifest(root.Name, [], [], []);
        if (rootName != root.Name) result.Warnings.Add($"Имя изменено: {root.Name} → {rootName}");
        if (root.Type == "file") { result.Files.Add(new(null, [rootName], root.Size, root.Md5, root.Sha256)); return result; }
        if (root.Type != "dir") throw new InvalidDataException("Неизвестный тип ресурса.");
        var queue = new Queue<(string? Api, string[] Local, Resource? Cached)>();
        queue.Enqueue((null, [rootName], root));
        result.Directories.Add([rootName]);
        var visited = new HashSet<string>(StringComparer.Ordinal) { "/" };
        while (queue.TryDequeue(out var folder))
        {
            var offset = 0;
            int? total = null;
            var current = folder.Cached;
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var remoteNames = new HashSet<string>(StringComparer.Ordinal);
            while (true)
            {
                token.ThrowIfCancellationRequested();
                Resource page;
                try { page = current ?? await api.Resource(key, folder.Api, offset, pageSize, token); }
                catch (Exception e) when (folder.Api != null && !token.IsCancellationRequested)
                { result.Warnings.Add($"Папка пропущена: {string.Join('/', folder.Local)}. {ErrorText.Safe(e)}"); break; }
                current = null;
                var listing = page.Embedded ?? throw new InvalidDataException("Нет списка файлов.");
                if (page.Type != "dir" || (listing.Offset != null && listing.Offset != offset) ||
                    (total != null && listing.Total != null && total != listing.Total))
                    throw new InvalidDataException("Содержимое папки изменилось. Проверьте ссылку заново.");
                total = listing.Total;
                if (listing.Items.Length == 0)
                {
                    if (total != null && offset < total) throw new InvalidDataException("Неполный список файлов.");
                    break;
                }
                foreach (var child in listing.Items)
                {
                    try
                    {
                        SafeNames.ValidateRemote(child.Name);
                        if (!remoteNames.Add(child.Name)) throw new InvalidDataException("Повтор имени в списке файлов.");
                        if (folder.Local.Length >= 64) throw new InvalidDataException("Слишком глубокая вложенность.");
                        var name = SafeNames.Reserve(SafeNames.Local(child.Name), names);
                        if (name != child.Name) result.Warnings.Add($"Имя изменено: {child.Name} → {name}");
                        var apiPath = child.Path ?? (folder.Api ?? "").TrimEnd('/') + "/" + child.Name;
                        SafeNames.ValidateApiPath(apiPath);
                        var components = folder.Local.Append(name).ToArray();
                        if (child.Type == "file")
                            result.Files.Add(new(apiPath, components, child.Size, child.Md5, child.Sha256));
                        else if (child.Type == "dir" && visited.Add(apiPath))
                        { result.Directories.Add(components); queue.Enqueue((apiPath, components, null)); }
                        else if (child.Type != "dir") result.Warnings.Add("Неизвестный ресурс пропущен: " + child.Name);
                        progress?.Invoke(result.Files.Count);
                    }
                    catch (InvalidDataException e) { result.Warnings.Add($"Ресурс пропущен: {child.Name}. {e.Message}"); }
                }
                offset += listing.Items.Length;
                if (total != null ? offset >= total : listing.Items.Length < pageSize) break;
            }
        }
        return result;
    }
}
