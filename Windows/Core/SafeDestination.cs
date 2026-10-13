using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

namespace YandexDiskDownloader.Core;

public sealed class SafeDestination
{
    private readonly string root;
    public SafeDestination(string destination)
    {
        root = Path.GetFullPath(destination);
        using var lease = LockDirectory(root, false);
    }
    public string FullPath(IEnumerable<string> components)
    {
        var names = components.ToArray();
        if (names.Any(n => SafeNames.Local(n) != n)) throw new InvalidDataException("Небезопасное локальное имя.");
        var result = Path.GetFullPath(Path.Combine([root, .. names]));
        var prefix = root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!result.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Путь вышел за выбранную папку.");
        return result;
    }
    public void CreateFolder(string[] components) { using var lease = LockDirectory(FullPath(components), true); }
    public async Task<bool> Matches(RemoteFile file, bool hashes, CancellationToken token)
    {
        var target = FullPath(file.Components);
        using var lease = LockDirectory(Path.GetDirectoryName(target)!, true);
        if (!File.Exists(target)) return false;
        if ((File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0) return false;
        // Windows denies replacement/deletion while this non-shared handle is open.
        try
        {
            await using var input = OpenReadNoFollow(target);
            if (file.Size == null && file.Md5 == null && file.Sha256 == null) return false;
            await FileTransfer.Verify(input, file, hashes, token);
            return true;
        }
        catch (InvalidDataException) { return false; }
    }
    public async Task<string> Publish(RemoteFile file, Stream source, CancellationToken token)
    {
        var target = FullPath(file.Components);
        var parent = Path.GetDirectoryName(target)!;
        using var lease = LockDirectory(parent, true);
        var staged = Path.Combine(parent, ".yandex-download-" + Guid.NewGuid() + ".part");
        try
        {
            await using (var output = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, FileOptions.Asynchronous))
            {
                source.Position = 0;
                await source.CopyToAsync(output, token);
                await output.FlushAsync(token);
                output.Flush(true);
            }
            for (var i = 0; i <= 10000; i++)
            {
                token.ThrowIfCancellationRequested();
                var name = Path.Combine(parent, SafeNames.Numbered(Path.GetFileName(target), i));
                try { File.Move(staged, name, false); return name; }
                catch (IOException) when (File.Exists(name) || Directory.Exists(name)) { }
            }
            throw new IOException("Слишком много совпадающих файлов.");
        }
        finally { if (File.Exists(staged)) File.Delete(staged); }
    }
    private static DirectoryLease LockDirectory(string full, bool create)
    {
        var lease = new DirectoryLease();
        try
        {
            var current = Path.GetPathRoot(full)!;
            lease.Add(current);
            foreach (var part in full[current.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, part);
                if (create && !Directory.Exists(current)) Directory.CreateDirectory(current);
                lease.Add(current);
            }
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }
    private static FileStream OpenReadNoFollow(string path)
    {
        if (!OperatingSystem.IsWindows())
            return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None, 131072, FileOptions.Asynchronous);
        var handle = CreateFileW(path, 0x80000000, 0, IntPtr.Zero, 3, 0x40200000, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Не удалось открыть существующий файл."); }
        if (!GetFileInformationByHandleEx(handle, 9, out var info, (uint)Marshal.SizeOf<AttributeTag>()) || (info.Attributes & 0x410) != 0)
        { handle.Dispose(); throw new InvalidDataException("Ссылка или папка не может считаться загруженным файлом."); }
        try { return new FileStream(handle, FileAccess.Read, 131072, true); }
        catch { handle.Dispose(); throw; }
    }
    private sealed class DirectoryLease : IDisposable
    {
        private readonly List<SafeFileHandle> handles = [];
        public void Add(string path)
        {
            var attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0)
                throw new InvalidDataException("Символические ссылки и junction-папки не используются для записи.");
            if (!OperatingSystem.IsWindows()) return;
            // Open the directory itself, without following its reparse point, and deny rename/delete.
            var handle = CreateFileW(path, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("Не удалось открыть выбранную папку безопасно."); }
            if (!GetFileInformationByHandleEx(handle, 9, out var info, (uint)Marshal.SizeOf<AttributeTag>()) ||
                (info.Attributes & 0x400) != 0 || (info.Attributes & 0x10) == 0)
            { handle.Dispose(); throw new InvalidDataException("Небезопасная папка."); }
            handles.Add(handle);
        }
        public void Dispose() { foreach (var handle in handles.AsEnumerable().Reverse()) handle.Dispose(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct AttributeTag { public uint Attributes; public uint Tag; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint sharing, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out AttributeTag info, uint size);
}
