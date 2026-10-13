using System.ComponentModel;
using System.Windows;
using Microsoft.Win32;

namespace YandexDiskDownloader.Windows;

public partial class MainWindow : Window
{
    private MainViewModel Model => (MainViewModel)DataContext;
    public MainWindow() { InitializeComponent(); DataContext = new MainViewModel(Dispatcher); }
    private async void Inspect(object sender, RoutedEventArgs e) => await Model.Inspect();
    private async void Start(object sender, RoutedEventArgs e) => await Model.Start(false);
    private async void Retry(object sender, RoutedEventArgs e) => await Model.Start(true);
    private void Pause(object sender, RoutedEventArgs e) => Model.Pause();
    private void Cancel(object sender, RoutedEventArgs e) => Model.Cancel();
    private void ChooseFolder(object sender, RoutedEventArgs e)
    {
        var picker = new OpenFolderDialog { Title = "Выберите папку для загрузки", Multiselect = false };
        if (picker.ShowDialog(this) == true) Model.Destination = picker.FolderName;
    }
    private void UseHistory(object sender, RoutedEventArgs e)
    {
        if (HistoryList.SelectedItem is HistoryEntry entry) Model.UseHistory(entry);
    }
    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (Model.CanCancel && MessageBox.Show(this, "Остановить загрузку и закрыть приложение?", "Yandex Disk Downloader", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
        { e.Cancel = true; return; }
        Model.Dispose();
    }
}
