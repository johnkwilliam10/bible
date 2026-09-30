import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' hide context;
import 'package:sqflite/sqflite.dart';

void main() => runApp(const BibleApp());

/* ================================================================== */
/*  DESIGN TOKENS                                                      */
/* ================================================================== */

class AppColors {
  static const Color seed = Color(0xFF1E3A8A);
  static const Color indigo = Color(0xFF1E3A8A);
  static const Color royal = Color(0xFF2563EB);
  static const Color sky = Color(0xFF3B82F6);
  static const Color gold = Color(0xFFE0A82E);

  static const Map<String, Color> _lang = <String, Color>{
    'en': Color(0xFF2563EB),
    'sw': Color(0xFF0E9F6E),
    'kik': Color(0xFFD97706),
  };

  static Color langColor(String code) => _lang[code] ?? royal;
}

class LanguageOption {
  final String code;
  final String label;
  final String version;
  final String flag;

  const LanguageOption({
    required this.code,
    required this.label,
    required this.version,
    required this.flag,
  });
}

const List<LanguageOption> kLanguages = <LanguageOption>[
  LanguageOption(
    code: 'en',
    label: 'English',
    version: 'King James Version',
    flag: '🇬🇧',
  ),
  LanguageOption(
    code: 'sw',
    label: 'Kiswahili',
    version: 'Swahili Bible',
    flag: '🇰🇪',
  ),
  LanguageOption(
    code: 'kik',
    label: 'Kikuyu',
    version: 'Kikuyu Bible',
    flag: '🇰🇪',
  ),
];

LanguageOption langOf(String code) => kLanguages.firstWhere(
      (LanguageOption l) => l.code == code,
      orElse: () => LanguageOption(
        code: code,
        label: code.toUpperCase(),
        version: 'Translation',
        flag: '🌐',
      ),
    );

/* ================================================================== */
/*  APP                                                                */
/* ================================================================== */

class BibleApp extends StatelessWidget {
  const BibleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parallel Bible Reader',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _premiumTheme(Brightness.light),
      darkTheme: _premiumTheme(Brightness.dark),
      home: const BibleReaderPage(),
    );
  }

  ThemeData _premiumTheme(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.seed,
      brightness: brightness,
    );
    final bool isDark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0A0E18) : const Color(0xFFF5F6FA),
      splashFactory: InkRipple.splashFactory,
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        backgroundColor:
            isDark ? const Color(0xFF1F2937) : const Color(0xFF111827),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }
}

/* ================================================================== */
/*  DATABASE HELPER (master_bible.sqlite)                              */
/* ================================================================== */

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('master_bible.sqlite');
    return _database!;
  }

  Future<Database> _initDB(String fileName) async {
    final String dbPath = await getDatabasesPath();
    final String path = join(dbPath, fileName);

    final bool exists = await databaseExists(path);

    if (!exists) {
      try {
        await Directory(dirname(path)).create(recursive: true);
        final ByteData data = await rootBundle.load(join('assets', fileName));
        final List<int> bytes =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await File(path).writeAsBytes(bytes, flush: true);
      } catch (e) {
        debugPrint('Error copying database: $e');
        rethrow;
      }
    }

    return openDatabase(path, readOnly: true);
  }

  Future<List<ParallelVerseModel>> getChapterVerses(
    int book,
    int chapter,
    List<String> langs,
  ) async {
    final Database db = await database;
    if (langs.isEmpty) return <ParallelVerseModel>[];

    final String placeholders = List.filled(langs.length, '?').join(',');

    // Query your master table columns: book, chapter, verse, translation_id, text
    final List<Map<String, dynamic>> rawData = await db.rawQuery('''
      SELECT verse, translation_id, text
      FROM verses
      WHERE book = ? AND chapter = ? AND translation_id IN ($placeholders)
      ORDER BY verse ASC
    ''', <Object?>[book, chapter, ...langs]);

    final Map<int, Map<String, String>> grouped = <int, Map<String, String>>{};
    for (final Map<String, dynamic> row in rawData) {
      final int vNum = row['verse'] as int;
      final String lang = row['translation_id'] as String;
      final String txt = row['text'] as String;
      grouped.putIfAbsent(vNum, () => <String, String>{})[lang] = txt;
    }

    final List<ParallelVerseModel> result = grouped.entries
        .map((MapEntry<int, Map<String, String>> e) =>
            ParallelVerseModel(verseNumber: e.key, texts: e.value))
        .toList()
      ..sort((ParallelVerseModel a, ParallelVerseModel b) =>
          a.verseNumber.compareTo(b.verseNumber));

    return result;
  }
}

class ParallelVerseModel {
  final int verseNumber;
  final Map<String, String> texts;

  ParallelVerseModel({required this.verseNumber, required this.texts});
}

/* ================================================================== */
/*  READER PAGE                                                        */
/* ================================================================== */

class BibleReaderPage extends StatefulWidget {
  const BibleReaderPage({super.key});

  @override
  State<BibleReaderPage> createState() => _BibleReaderPageState();
}

class _BibleReaderPageState extends State<BibleReaderPage> {
  List<String> _selectedLanguages = <String>['en', 'sw', 'kik'];
  final int _currentBook = 1; // Genesis (Book ID 1)
  final int _currentChapter = 1; // Chapter 1
  double _fontScale = 1.0;

  late Future<List<ParallelVerseModel>> _versesFuture;

  static const Map<int, String> _bookNames = <int, String>{
    1: 'Genesis',
    2: 'Exodus',
    3: 'Leviticus',
    4: 'Numbers',
    5: 'Deuteronomy',
  };

  String get _bookName => _bookNames[_currentBook] ?? 'Book $_currentBook';

  @override
  void initState() {
    super.initState();
    _loadVerses();
  }

  void _loadVerses() {
    _versesFuture = DatabaseHelper.instance.getChapterVerses(
      _currentBook,
      _currentChapter,
      _selectedLanguages,
    );
  }

  /* ---------------- actions ---------------- */

  void _copyVerse(BuildContext ctx, ParallelVerseModel verse) {
    final StringBuffer buffer = StringBuffer();
    for (final String code in _selectedLanguages) {
      final String? t = verse.texts[code];
      if (t == null || t.trim().isEmpty) continue;
      buffer.writeln('${code.toUpperCase()}: $t');
    }
    final String content = buffer.toString().trim();
    if (content.isEmpty) return;

    Clipboard.setData(ClipboardData(
      text: '$_bookName $_currentChapter:${verse.verseNumber}\n$content',
    ));
    HapticFeedback.mediumImpact();

    ScaffoldMessenger.of(ctx)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: <Widget>[
              const Icon(Icons.check_circle_rounded,
                  color: Color(0xFF4ADE80), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Verse ${verse.verseNumber} copied to clipboard'),
              ),
            ],
          ),
          duration: const Duration(milliseconds: 1500),
        ),
      );
  }

  void _toggleLanguage(
    BuildContext ctx,
    String code,
    StateSetter setModalState,
  ) {
    setModalState(() {
      if (_selectedLanguages.contains(code)) {
        if (_selectedLanguages.length > 1) {
          _selectedLanguages.remove(code);
          HapticFeedback.selectionClick();
        } else {
          HapticFeedback.heavyImpact();
          ScaffoldMessenger.of(ctx)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('Keep at least one language selected.'),
                duration: Duration(milliseconds: 1400),
              ),
            );
        }
      } else {
        _selectedLanguages.add(code);
        HapticFeedback.selectionClick();
      }
    });
  }

  void _applySettings() {
    _selectedLanguages.sort((String a, String b) {
      final int ia = kLanguages.indexWhere((LanguageOption l) => l.code == a);
      final int ib = kLanguages.indexWhere((LanguageOption l) => l.code == b);
      return ia.compareTo(ib);
    });
    setState(_loadVerses);
  }

  /* ---------------- settings sheet ---------------- */

  void _openSettingsModal() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (BuildContext sheetContext) {
        final ColorScheme scheme = Theme.of(sheetContext).colorScheme;

        return StatefulBuilder(
          builder: (BuildContext modalContext, StateSetter setModalState) {
            return Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(30)),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withOpacity(0.28),
                    blurRadius: 34,
                    offset: const Offset(0, -10),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Center(
                          child: Container(
                            width: 46,
                            height: 5,
                            decoration: BoxDecoration(
                              color: scheme.onSurfaceVariant.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        Row(
                          children: <Widget>[
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: <Color>[
                                    AppColors.royal,
                                    AppColors.indigo
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(Icons.tune_rounded,
                                  color: Colors.white, size: 22),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'Reading Preferences',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.3,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Customise your parallel experience',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 26),
                        _sectionLabel(scheme, 'LANGUAGES'),
                        const SizedBox(height: 12),
                        for (final LanguageOption opt in kLanguages)
                          _languageTile(modalContext, opt, setModalState),
                        const SizedBox(height: 22),
                        _sectionLabel(scheme, 'TEXT SIZE'),
                        const SizedBox(height: 6),
                        Row(
                          children: <Widget>[
                            Text('A',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSurfaceVariant)),
                            Expanded(
                              child: Slider(
                                value: _fontScale,
                                min: 0.9,
                                max: 1.4,
                                divisions: 5,
                                label: '${(_fontScale * 100).round()}%',
                                activeColor: AppColors.royal,
                                onChanged: (double v) =>
                                    setModalState(() => _fontScale = v),
                              ),
                            ),
                            Text('A',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ),
                        const SizedBox(height: 22),
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: <Color>[
                                  AppColors.royal,
                                  AppColors.indigo
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: AppColors.royal.withOpacity(0.38),
                                  blurRadius: 20,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () {
                                  _applySettings();
                                  Navigator.of(modalContext).pop();
                                },
                                child: const Center(
                                  child: Text(
                                    'Apply Changes',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sectionLabel(ColorScheme scheme, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.4,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _languageTile(
    BuildContext ctx,
    LanguageOption opt,
    StateSetter setModalState,
  ) {
    final ColorScheme scheme = Theme.of(ctx).colorScheme;
    final bool selected = _selectedLanguages.contains(opt.code);
    final Color accent = AppColors.langColor(opt.code);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _toggleLanguage(ctx, opt.code, setModalState),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withOpacity(0.10)
                  : scheme.surfaceVariant.withOpacity(0.30),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? accent.withOpacity(0.55)
                    : scheme.outlineVariant.withOpacity(0.35),
                width: 1.4,
              ),
            ),
            child: Row(
              children: <Widget>[
                Text(opt.flag, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        opt.label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        opt.version,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? accent : Colors.transparent,
                    border: Border.all(
                      color:
                          selected ? accent : scheme.outline.withOpacity(0.5),
                      width: 1.8,
                    ),
                  ),
                  child: selected
                      ? const Icon(Icons.check_rounded,
                          size: 15, color: Colors.white)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /* ---------------- header ---------------- */

  Widget _buildHeader(BuildContext outerContext) {
    final double topInset = MediaQuery.of(outerContext).padding.top;

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AppColors.indigo,
            AppColors.royal,
            AppColors.sky,
          ],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.indigo.withOpacity(0.38),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
        child: Stack(
          children: <Widget>[
            Positioned(
              top: -70,
              right: -50,
              child: _glowCircle(180, Colors.white.withOpacity(0.10)),
            ),
            Positioned(
              bottom: -80,
              left: -40,
              child: _glowCircle(150, Colors.white.withOpacity(0.07)),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, topInset + 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.28),
                          ),
                        ),
                        child: const Icon(Icons.auto_stories_rounded,
                            color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '$_bookName $_currentChapter',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 23,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'PARALLEL READER ENGINE',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.72),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _glassButton(
                        icon: Icons.tune_rounded,
                        tooltip: 'Reading Preferences',
                        onTap: _openSettingsModal,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 34,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.zero,
                      itemCount: _selectedLanguages.length,
                      separatorBuilder: (BuildContext c, int i) =>
                          const SizedBox(width: 8),
                      itemBuilder: (BuildContext c, int i) {
                        final LanguageOption opt =
                            langOf(_selectedLanguages[i]);
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.16),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.28),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Text(opt.flag,
                                  style: const TextStyle(fontSize: 13)),
                              const SizedBox(width: 7),
                              Text(
                                opt.label,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _glowCircle(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );

  Widget _glassButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.28)),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  /* ---------------- body ---------------- */

  Widget _buildBody(BuildContext outerContext) {
    return FutureBuilder<List<ParallelVerseModel>>(
      future: _versesFuture,
      builder: (
        BuildContext futureContext,
        AsyncSnapshot<List<ParallelVerseModel>> snapshot,
      ) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SkeletonList();
        }

        if (snapshot.hasError) {
          return _stateMessage(
            futureContext,
            icon: Icons.error_outline_rounded,
            title: 'Unable to open the library',
            subtitle: '${snapshot.error}',
          );
        }

        final List<ParallelVerseModel>? verses = snapshot.data;
        if (verses == null || verses.isEmpty) {
          return _stateMessage(
            futureContext,
            icon: Icons.menu_book_rounded,
            title: 'No verses found',
            subtitle: 'Try selecting a different set of languages.',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          itemCount: verses.length,
          itemBuilder: (BuildContext itemContext, int index) {
            final ParallelVerseModel verse = verses[index];
            return _FadeSlideIn(
              index: index,
              child: _VerseCard(
                verse: verse,
                languages: _selectedLanguages,
                fontScale: _fontScale,
                onCopy: () => _copyVerse(itemContext, verse),
              ),
            );
          },
        );
      },
    );
  }

  Widget _stateMessage(
    BuildContext ctx, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final ColorScheme scheme = Theme.of(ctx).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: scheme.primary),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          _buildHeader(context),
          Expanded(child: _buildBody(context)),
        ],
      ),
      bottomNavigationBar: const PoweredByFooter(),
    );
  }
}

/* ================================================================== */
/*  VERSE CARD                                                         */
/* ================================================================== */

class _VerseCard extends StatelessWidget {
  final ParallelVerseModel verse;
  final List<String> languages;
  final double fontScale;
  final VoidCallback onCopy;

  const _VerseCard({
    required this.verse,
    required this.languages,
    required this.fontScale,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isDark = scheme.brightness == Brightness.dark;

    final List<String> visible = languages
        .where((String l) => (verse.texts[l] ?? '').trim().isNotEmpty)
        .toList();

    if (visible.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.primary.withOpacity(isDark ? 0.20 : 0.09),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.30 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onCopy,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _VerseBadge(number: verse.verseNumber),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (int i = 0; i < visible.length; i++)
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: i == visible.length - 1 ? 0 : 14,
                          ),
                          child: _LanguageBlock(
                            code: visible[i],
                            text: verse.texts[visible[i]]!,
                            fontScale: fontScale,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VerseBadge extends StatelessWidget {
  final int number;
  const _VerseBadge({required this.number});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[AppColors.royal, AppColors.indigo],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.royal.withOpacity(0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        '$number',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
      ),
    );
  }
}

class _LanguageBlock extends StatelessWidget {
  final String code;
  final String text;
  final double fontScale;

  const _LanguageBlock({
    required this.code,
    required this.text,
    required this.fontScale,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color accent = AppColors.langColor(code);
    final LanguageOption opt = langOf(code);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.14),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: accent.withOpacity(0.28)),
              ),
              child: Text(
                code.toUpperCase(),
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.9,
                  color: accent,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                opt.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          text,
          style: TextStyle(
            fontSize: 16 * fontScale,
            height: 1.55,
            letterSpacing: 0.1,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

/* ================================================================== */
/*  ANIMATION HELPERS                                                  */
/* ================================================================== */

class _FadeSlideIn extends StatefulWidget {
  final Widget child;
  final int index;

  const _FadeSlideIn({required this.child, required this.index});

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 430),
  );

  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    final Duration delay = Duration(milliseconds: (widget.index % 12) * 45);
    Future<void>.delayed(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext buildCtx, Widget? _) {
        final double o = 0.18 + (_c.value * 0.28);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 6,
          itemBuilder: (BuildContext itemCtx, int index) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.primary.withOpacity(0.06)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _skeletonBar(scheme, 36, 36, o, radius: 12),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _skeletonBar(scheme, 70, 10, o),
                      const SizedBox(height: 11),
                      _skeletonBar(scheme, double.infinity, 12, o),
                      const SizedBox(height: 8),
                      _skeletonBar(scheme, 190, 12, o),
                      const SizedBox(height: 18),
                      _skeletonBar(scheme, 70, 10, o),
                      const SizedBox(height: 11),
                      _skeletonBar(scheme, double.infinity, 12, o),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Widget _skeletonBar(
  ColorScheme scheme,
  double width,
  double height,
  double opacity, {
  double radius = 6,
}) {
  return Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: scheme.onSurface.withOpacity(opacity * 0.35),
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/* ================================================================== */
/*  FOOTER                                                             */
/* ================================================================== */

class PoweredByFooter extends StatelessWidget {
  const PoweredByFooter({super.key});

  static const String email = 'johnkwilliam10@gmail.com';

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool isDark = scheme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.primary.withOpacity(0.14)),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.45 : 0.07),
            blurRadius: 18,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: InkWell(
          onTap: () async {
            final ScaffoldMessengerState messenger =
                ScaffoldMessenger.of(context);
            await Clipboard.setData(const ClipboardData(text: email));
            HapticFeedback.lightImpact();
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Row(
                    children: <Widget>[
                      const Icon(Icons.mail_rounded,
                          color: Color(0xFF93C5FD), size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Email copied: $email')),
                    ],
                  ),
                  duration: const Duration(milliseconds: 1600),
                ),
              );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.verified_rounded,
                    size: 15, color: AppColors.gold),
                const SizedBox(width: 8),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(
                          text: 'Powered by John',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                            letterSpacing: 0.2,
                          ),
                        ),
                        TextSpan(
                          text: ':  Email  ',
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        TextSpan(
                          text: email,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
