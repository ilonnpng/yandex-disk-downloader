using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Threading;
using YandexDiskDownloader.Core;

namespace YandexDiskDownloader.Windows;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    { if (EqualityComparer<T>.Default.Equals(field, value)) return false; field = value; Changed(name); return true; }
}
public enum FileState { Pending, Downloading, Paused, Complete, Skipped, Failed }
public sealed class FileRow(RemoteFile file) : Observable
{
    public RemoteFile File { get; } = file;
    public string Name => string.Join('/', File.Components);
    public string SizeText => File.Size is { } size ? MainViewModel.Bytes(size) : "—";
    public PartialTransfer? Partial { get; set; }
    private long bytes;
    public long Bytes { get => bytes; set { if (Set(ref bytes, value)) Changed(nameof(Detail)); } }
    private FileState state;
    public FileState State { get => state; set { if (Set(ref state, value)) Changed(nameof(Detail)); } }
    private string error = "";
    public string Error { get => error; set { if (Set(ref error, value)) Changed(nameof(Detail)); } }
    public string Detail => State switch
    {
        FileState.Downloading => "Загрузка · " + MainViewModel.Bytes(Bytes),
        FileState.Paused => "Пауза · " + MainViewModel.Bytes(Bytes),
        FileState.Complete => "Готово",
        FileState.Skipped => "Уже загружен",
        FileState.Failed => Error,
        _ => "В очереди"
    };
}
public sealed record HistoryEntry(string Link, string Destination, DateTimeOffset Date, int Completed, int Failed)
{
    public string Display => $"{Date.LocalDateTime:g} · {Completed} готово, {Failed} ошибок · {Link}";
}
public sealed record Settings(string Link, string Destination, int Parallelism, bool VerifyHashes, bool SkipExisting, List<HistoryEntry> History);

public sealed class MainViewModel : Observable, IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly HttpClient http;
    private readonly bool persist;
    private readonly DiskApi api;
    private readonly DispatcherTimer timer;
    private readonly Stopwatch clock = new();
    private long baseline;
    private Manifest? manifest;
    private string? inspectedKey;
    private CancellationTokenSource? cancellation;
    private bool busy, paused, pauseRequested, cancelRequested, disposed;
    private readonly string settingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YandexDiskDownloader", "settings.json");
    public ObservableCollection<FileRow> Files { get; } = [];
    public ObservableCollection<string> Warnings { get; } = [];
    public ObservableCollection<HistoryEntry> History { get; } = [];
    public int[] ParallelOptions { get; } = [1, 2, 3, 5, 8];
    private string link = "", destination = "", status = "Вставьте публичную ссылку и нажмите «Проверить».";
    private int parallelism = 3;
    private bool verifyHashes = true, skipExisting = true, inspecting;
    public string Link
    {
        get => link;
        set { if (Set(ref link, value) && !busy && !paused) { manifest = null; inspectedKey = null; ClearPartials(); Files.Clear(); Refresh(); } }
    }
    public string Destination { get => destination; set { if (Set(ref destination, value)) { Save(); Refresh(); } } }
    public int Parallelism { get => parallelism; set { if (ParallelOptions.Contains(value) && Set(ref parallelism, value)) Save(); } }
    public bool VerifyHashes { get => verifyHashes; set { if (Set(ref verifyHashes, value)) Save(); } }
    public bool SkipExisting { get => skipExisting; set { if (Set(ref skipExisting, value)) Save(); } }
    public string Status { get => status; private set => Set(ref status, value); }
    public bool Inspecting { get => inspecting; private set { Set(ref inspecting, value); Refresh(); } }
    public bool CanEdit => !busy && !paused;
    public bool CanStart => !busy && manifest != null && (Files.Any(x => x.State is FileState.Pending or FileState.Paused) || Files.Count == 0 && manifest.Directories.Count > 0) && !string.IsNullOrWhiteSpace(Destination);
    public bool CanPause => busy && !Inspecting && !pauseRequested && !cancelRequested;
    public bool CanCancel => busy || paused;
    public bool CanRetry => !busy && !paused && Files.Any(x => x.State == FileState.Failed) && !string.IsNullOrWhiteSpace(Destination);
    public string StartLabel => paused ? "Продолжить" : "Скачать";
    private long CompletedBytes => Files.Sum(x => x.State is FileState.Complete or FileState.Skipped ? Math.Max(0, x.File.Size ?? x.Bytes) : x.Bytes);
    public double Progress => manifest == null || Files.Count == 0 ? 0 : manifest.KnownSize && manifest.TotalSize > 0
        ? Math.Clamp(100d * CompletedBytes / manifest.TotalSize, 0, 100)
        : 100d * Files.Count(x => x.State is FileState.Complete or FileState.Skipped) / Files.Count;
    public string Summary
    {
        get
        {
            if (manifest == null) return "";
            var done = Files.Count(x => x.State is FileState.Complete or FileState.Skipped);
            var failed = Files.Count(x => x.State == FileState.Failed);
            var speed = clock.IsRunning && clock.Elapsed.TotalSeconds > 0 ? Math.Max(0, CompletedBytes - baseline) / clock.Elapsed.TotalSeconds : 0;
            var eta = manifest.KnownSize && speed > 0 ? " · осталось ~" + TimeSpan.FromSeconds(Math.Min(8640000, Math.Max(0, manifest.TotalSize - CompletedBytes) / speed)).ToString(@"hh\:mm\:ss") : "";
            return $"{done} / {Files.Count} файлов · ошибок: {failed} · {Bytes(CompletedBytes)}" +
                (manifest.KnownSize ? " / " + Bytes(manifest.TotalSize) : "") + (speed > 0 ? " · " + Bytes((long)speed) + "/с" + eta : "");
        }
    }
    public MainViewModel(Dispatcher dispatcher, HttpClient? client = null, bool persist = true)
    {
        this.dispatcher = dispatcher; this.persist = persist; http = client ?? DiskApi.CreateClient(); api = new(http);
        try
        {
            if (persist && File.Exists(settingsPath) && new FileInfo(settingsPath).Length < 2_000_000)
            {
                var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(settingsPath));
                if (settings != null)
                {
                    link = settings.Link; destination = settings.Destination;
                    parallelism = ParallelOptions.Contains(settings.Parallelism) ? settings.Parallelism : 3;
                    verifyHashes = settings.VerifyHashes; skipExisting = settings.SkipExisting;
                    foreach (var entry in settings.History.Take(200)) History.Add(entry);
                }
            }
        }
        catch { Status = "Не удалось прочитать настройки; используются стандартные значения."; }
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(400), DispatcherPriority.Background, (_, _) => RefreshStats(), dispatcher);
    }
    public async Task Inspect()
    {
        if (!CanEdit) return;
        busy = true; Inspecting = true; pauseRequested = cancelRequested = false; cancellation = new();
        ClearPartials(); Files.Clear(); Warnings.Clear(); manifest = null; inspectedKey = null;
        Status = "Проверка папки…"; Refresh();
        try
        {
            var key = PublicLink.Validate(Link);
            var result = await new FolderScanner(api).Scan(key, count => dispatcher.BeginInvoke(new Action(() =>
            { if (!disposed && Inspecting) Status = $"Найдено файлов: {count}…"; })), cancellation.Token);
            manifest = result; inspectedKey = key;
            foreach (var file in result.Files) Files.Add(new(file));
            foreach (var warning in result.Warnings) Warnings.Add(warning);
            Status = $"{result.Name} · {Files.Count} файлов. Выберите папку и нажмите «Скачать».";
            Save();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { Status = "Проверка отменена."; }
        catch (Exception e) { Status = ErrorText.Safe(e); }
        finally { busy = false; Inspecting = false; cancellation.Dispose(); cancellation = null; Refresh(); }
    }
    public async Task Start(bool retry)
    {
        if (busy || manifest == null || inspectedKey == null || (retry ? !CanRetry : !CanStart)) return;
        if (retry) foreach (var row in Files.Where(x => x.State == FileState.Failed)) { row.State = FileState.Pending; row.Error = ""; }
        var queue = Files.Where(x => x.State is FileState.Pending or FileState.Paused).ToArray();
        var key = inspectedKey; var hashes = VerifyHashes; var skip = SkipExisting; var degree = Parallelism;
        busy = true; paused = false; pauseRequested = cancelRequested = false; cancellation = new();
        baseline = CompletedBytes; clock.Restart(); Status = "Загрузка…"; Refresh();
        try
        {
            var target = new SafeDestination(Destination);
            foreach (var folder in manifest.Directories)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                try { target.CreateFolder(folder); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                { Warnings.Add("Папка пропущена: " + string.Join('/', folder) + ". " + ErrorText.Safe(e)); }
            }
            await Parallel.ForEachAsync(queue, new ParallelOptions { MaxDegreeOfParallelism = degree, CancellationToken = cancellation.Token },
                async (row, token) =>
                {
                    try
                    {
                        await Ui(() => row.State = FileState.Downloading);
                        if (skip && await target.Matches(row.File, hashes, token))
                        { await Ui(() => { row.State = FileState.Skipped; row.Partial?.Dispose(); row.Partial = null; }); return; }
                        row.Partial ??= new();
                        var url = await api.DownloadUrl(key, row.File.ApiPath, token);
                        var progressClock = Stopwatch.StartNew();
                        await new FileTransfer(http).Download(url, row.File, row.Partial, count =>
                        {
                            if (progressClock.ElapsedMilliseconds < 150) return;
                            progressClock.Restart();
                            dispatcher.BeginInvoke(new Action(() => { if (!disposed) row.Bytes = count; }));
                        }, token);
                        await FileTransfer.Verify(row.Partial.Stream, row.File, hashes, token);
                        var saved = await target.Publish(row.File, row.Partial.Stream, token);
                        var length = row.Partial.Stream.Length; row.Partial.Dispose(); row.Partial = null;
                        await Ui(() =>
                        {
                            row.Bytes = length; row.State = FileState.Complete;
                            if (Path.GetFileName(saved) != row.File.Components[^1]) Warnings.Add("Совпадение имён: сохранено как " + Path.GetFileName(saved));
                        });
                    }
                    catch (OperationCanceledException) when (token.IsCancellationRequested)
                    { await Ui(() => { row.Bytes = row.Partial?.Stream.Length ?? 0; row.State = FileState.Paused; }); }
                    catch (Exception e)
                    {
                        if (e is HttpStatusException { Status: 429 } limit) await api.Cooldown(limit.RetryAfter ?? TimeSpan.FromSeconds(2));
                        row.Partial?.Dispose(); row.Partial = null;
                        await Ui(() => { row.Bytes = 0; row.State = FileState.Failed; row.Error = ErrorText.Safe(e); });
                    }
                });
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception e) { Status = ErrorText.Safe(e); cancelRequested = true; }
        finally
        {
            busy = false; paused = pauseRequested && !cancelRequested && Files.Any(x => x.State is FileState.Pending or FileState.Paused); clock.Stop();
            cancellation.Dispose(); cancellation = null;
            if (paused) Status = "Пауза. Нажмите «Продолжить», чтобы продолжить очередь.";
            else if (cancelRequested) { ClearPartials(); foreach (var row in Files.Where(x => x.State == FileState.Paused)) { row.State = FileState.Pending; row.Bytes = 0; } Status = "Загрузка остановлена. Готовые файлы сохранены."; }
            else
            {
                Status = Files.Any(x => x.State == FileState.Failed) ? "Очередь завершена. Неудачные файлы можно повторить." : "Загрузка завершена.";
                History.Insert(0, new(key, Destination, DateTimeOffset.Now, Files.Count(x => x.State is FileState.Complete or FileState.Skipped), Files.Count(x => x.State == FileState.Failed)));
                while (History.Count > 200) History.RemoveAt(History.Count - 1);
            }
            Save(); Refresh();
        }
    }
    public void Pause() { if (!CanPause) return; pauseRequested = true; Status = "Приостановка…"; cancellation?.Cancel(); Refresh(); }
    public void Cancel()
    {
        cancelRequested = true; pauseRequested = false; cancellation?.Cancel();
        if (!busy) { paused = false; ClearPartials(); foreach (var row in Files.Where(x => x.State == FileState.Paused)) { row.State = FileState.Pending; row.Bytes = 0; } Status = "Загрузка остановлена."; }
        Refresh();
    }
    public void UseHistory(HistoryEntry entry) { if (CanEdit) { Link = entry.Link; Destination = entry.Destination; Status = "Нажмите «Проверить», чтобы получить актуальный список файлов."; } }
    private Task Ui(Action action) => dispatcher.InvokeAsync(action).Task;
    private void ClearPartials() { foreach (var row in Files) { row.Partial?.Dispose(); row.Partial = null; } }
    private void RefreshStats() { Changed(nameof(Progress)); Changed(nameof(Summary)); }
    private void Refresh()
    {
        foreach (var name in new[] { nameof(CanEdit), nameof(CanStart), nameof(CanPause), nameof(CanCancel), nameof(CanRetry), nameof(StartLabel) }) Changed(name);
        RefreshStats();
    }
    private void Save()
    {
        if (!persist) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
            var temporary = settingsPath + "." + Guid.NewGuid() + ".tmp";
            try { File.WriteAllText(temporary, JsonSerializer.Serialize(new Settings(Link, Destination, Parallelism, VerifyHashes, SkipExisting, History.ToList()))); File.Move(temporary, settingsPath, true); }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        catch { /* Settings are optional; download files remain unaffected. */ }
    }
    public static string Bytes(long value)
    {
        double number = Math.Max(0, value); string[] units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]; var i = 0;
        while (number >= 1024 && i < units.Length - 1) { number /= 1024; i++; }
        return $"{number:0.#} {units[i]}";
    }
    public void Dispose() { disposed = true; cancellation?.Cancel(); timer.Stop(); Save(); http.Dispose(); if (!busy) ClearPartials(); }
}
