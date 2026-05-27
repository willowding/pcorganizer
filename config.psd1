@{
    # ─── 游戏迁移目标（按优先级排，脚本自动选剩余空间最大的那个）
    GameTargets      = @('C:\Games', 'D:\Games', 'E:\Games')

    # ─── AI 资料根目录（过渡阶段放 E 盘子目录）
    AIRoot           = 'E:\AI'

    # ─── 虚拟盘盘符（subst 映射 AIRoot → 该盘符）
    AIDriveLetter    = 'F'

    # ─── 被识别为游戏的目录最小体积（GB）
    GameMinSizeGB    = 1

    # ─── 启动器路径关键字（用于快速定位游戏库根，支持通配符）
    LauncherPatterns = @(
        '*\Steam\steamapps\common'
        '*\Epic Games'
        '*\GOG Galaxy\Games'
        '*\Riot Games'
        '*\Battle.net'
        '*\Ubisoft\Ubisoft Game Launcher\games'
        '*\EA Games'
        '*\Origin Games'
        '*\XboxGames'
        '*\Blizzard Entertainment'
    )

    # ─── 游戏白名单（即使体积小也强制迁移，精确目录名）
    GameWhitelist    = @()

    # ─── 游戏黑名单（命中则跳过，支持通配符）
    GameBlacklist    = @(
        'WindowsApps'
        'Microsoft.*'
        'ModifiableWindowsApps'
    )

    # ─── AI 资料：模型权重后缀
    ModelExtensions  = @('.safetensors', '.gguf', '.ckpt', '.pt', '.pth',
                          '.bin', '.onnx', '.tflite', '.pb', '.h5', '.mlmodel')

    # ─── AI 资料：数据集后缀
    DatasetExtensions = @('.parquet', '.arrow', '.jsonl', '.tfrecord',
                           '.npz', '.npy', '.csv', '.tsv')

    # ─── AI 资料：数据集目录名关键字（小写匹配）
    DatasetDirKeywords = @('dataset', 'datasets', 'corpus', 'corpora', 'train',
                            'training_data', 'finetune', 'fine-tune')

    # ─── 知识库文档后缀（>=50 个文件才整体归类为 docs）
    DocExtensions    = @('.pdf', '.epub', '.md', '.docx', '.txt', '.rst', '.html')
    DocMinCount      = 50

    # ─── 存档扫描根目录（%xxx% 变量会在运行时展开）
    SaveRoots        = @(
        '%USERPROFILE%\Documents\My Games'
        '%USERPROFILE%\Documents\Saved Games'
        '%USERPROFILE%\Saved Games'
        '%LOCALAPPDATA%\Packages'
        '%APPDATA%\Roaming'
        '%LOCALAPPDATA%'
    )
}
