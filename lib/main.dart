import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  runApp(const PasswordVaultApp());
}

class PasswordVaultApp extends StatelessWidget {
  const PasswordVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mon coffre',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3559C7),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const VaultHomePage(),
    );
  }
}

class PasswordEntry {
  const PasswordEntry({
    required this.title,
    required this.login,
    required this.password,
  });

  final String title;
  final String login;
  final String password;

  Map<String, String> toJson() => {
    'title': title,
    'login': login,
    'password': password,
  };

  factory PasswordEntry.fromJson(Map<String, dynamic> json) {
    final title = json['title'];
    final login = json['login'];
    final password = json['password'];
    if (title is! String || login is! String || password is! String) {
      throw const FormatException('Une entrée du coffre est invalide.');
    }
    return PasswordEntry(title: title, login: login, password: password);
  }
}

class _EditorResult {
  const _EditorResult.saved(this.entry) : deleted = false;
  const _EditorResult.deleted() : entry = null, deleted = true;

  final PasswordEntry? entry;
  final bool deleted;
}

class VaultHomePage extends StatefulWidget {
  const VaultHomePage({super.key});

  @override
  State<VaultHomePage> createState() => _VaultHomePageState();
}

class _VaultHomePageState extends State<VaultHomePage>
    with WidgetsBindingObserver {
  static const _saltKey = 'vault.pin.salt';
  static const _hashKey = 'vault.pin.hash';
  static const _recoveryHashKey = 'vault.recovery.hash';
  static const _entriesKey = 'vault.entries';
  static const _failuresKey = 'vault.pin.failures';
  static const _maximumFailures = 10;

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  List<PasswordEntry> _entries = [];
  bool _loading = true;
  bool _configured = false;
  bool _hasRecoveryKey = false;
  bool _unlocked = false;
  bool _busy = false;
  int _failures = 0;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadVault();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _unlocked && mounted) {
      _lockVault();
    }
  }

  void _lockVault() {
    setState(() {
      _unlocked = false;
      _entries = [];
    });
  }

  Future<void> _loadVault() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final storedHash = await _storage.read(key: _hashKey);
      final storedRecoveryHash = await _storage.read(key: _recoveryHashKey);
      final failures = int.tryParse(
        await _storage.read(key: _failuresKey) ?? '0',
      );
      if (!mounted) return;
      setState(() {
        _configured = storedHash != null;
        _hasRecoveryKey = storedRecoveryHash != null;
        _failures = failures ?? 0;
        _entries = [];
        _loading = false;
        _unlocked = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Impossible de lire le coffre sécurisé : $error';
      });
    }
  }

  String _newSalt() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  String _newRecoveryKey() {
    final random = Random.secure();
    final secret = List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return List<String>.generate(
      8,
      (index) => secret.substring(index * 8, (index + 1) * 8),
    ).join('-');
  }

  String _normalizeRecoveryKey(String key) =>
      key.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();

  String _hashRecoveryKey(String key) =>
      sha256.convert(utf8.encode(_normalizeRecoveryKey(key))).toString();

  bool _constantTimeEquals(String first, String second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first.codeUnitAt(index) ^ second.codeUnitAt(index);
    }
    return difference == 0;
  }

  Future<List<PasswordEntry>> _readEntries() async {
    final encodedEntries = await _storage.read(key: _entriesKey);
    if (encodedEntries == null) return [];
    return (jsonDecode(encodedEntries) as List<dynamic>)
        .map(
          (item) =>
              PasswordEntry.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  Future<String> _hashPin(String pin, String salt) async {
    var digest = sha256.convert(utf8.encode('$salt:$pin')).toString();
    for (var i = 0; i < 100000; i++) {
      digest = sha256.convert(utf8.encode('$salt:$pin:$digest')).toString();
      if (i % 5000 == 4999) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return digest;
  }

  Future<void> _createVault(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final recoveryKey = _newRecoveryKey();
      final salt = _newSalt();
      final hash = await _hashPin(pin, salt);
      await _storage.write(key: _saltKey, value: salt);
      await _storage.write(key: _hashKey, value: hash);
      await _storage.write(
        key: _recoveryHashKey,
        value: _hashRecoveryKey(recoveryKey),
      );
      await _storage.write(key: _entriesKey, value: '[]');
      await _storage.write(key: _failuresKey, value: '0');
      if (!mounted) return;
      setState(() {
        _configured = true;
        _hasRecoveryKey = true;
        _unlocked = true;
        _entries = [];
        _failures = 0;
        _busy = false;
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _RecoveryKeyDialog(recoveryKey: recoveryKey),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Impossible de créer le coffre sécurisé : $error';
      });
    }
  }

  Future<void> _unlockVault(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final salt = await _storage.read(key: _saltKey);
      final expectedHash = await _storage.read(key: _hashKey);
      if (salt == null || expectedHash == null) {
        throw StateError('Le code principal du coffre est introuvable.');
      }
      final actualHash = await _hashPin(pin, salt);
      if (_constantTimeEquals(actualHash, expectedHash)) {
        final entries = await _readEntries();
        await _storage.write(key: _failuresKey, value: '0');
        if (!mounted) return;
        setState(() {
          _busy = false;
          _failures = 0;
          _entries = entries;
          _unlocked = true;
        });
        return;
      }

      final failures = _failures + 1;
      await _storage.write(key: _failuresKey, value: '$failures');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failures = failures;
        _error = failures >= _maximumFailures
            ? 'Dix codes incorrects. Le déverrouillage est suspendu : utilisez votre clé de récupération ou réinitialisez le coffre.'
            : 'Code incorrect. Il vous reste ${_maximumFailures - failures} '
                  'tentative${_maximumFailures - failures == 1 ? '' : 's'}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Impossible de déverrouiller le coffre : $error';
      });
    }
  }

  Future<String?> _verifyRecoveryKey(String recoveryKey) async {
    try {
      final expectedHash = await _storage.read(key: _recoveryHashKey);
      if (expectedHash == null) {
        return 'Aucune clé de récupération n’a été configurée pour ce coffre. Vous pouvez le réinitialiser, mais ses entrées seront effacées.';
      }
      if (!_constantTimeEquals(_hashRecoveryKey(recoveryKey), expectedHash)) {
        return 'Clé de récupération incorrecte.';
      }
      return null;
    } catch (error) {
      return 'Impossible de vérifier la clé de récupération : $error';
    }
  }

  Future<String?> _recoverVault(String recoveryKey, String newPin) async {
    if (!mounted) return 'Cette page n’est plus disponible.';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verificationError = await _verifyRecoveryKey(recoveryKey);
      if (verificationError != null) return verificationError;

      final entries = await _readEntries();
      final salt = _newSalt();
      final hash = await _hashPin(newPin, salt);
      await _storage.write(key: _saltKey, value: salt);
      await _storage.write(key: _hashKey, value: hash);
      await _storage.write(key: _failuresKey, value: '0');
      if (!mounted) return 'Cette page n’est plus disponible.';
      setState(() {
        _busy = false;
        _failures = 0;
        _entries = entries;
        _unlocked = true;
        _error = null;
        _notice = 'Code principal remplacé. Vos entrées ont été conservées.';
      });
      return null;
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Impossible de récupérer le coffre : $error';
        });
      }
      return 'Impossible de récupérer le coffre : $error';
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _resetVault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Réinitialiser le coffre ?'),
        content: const Text(
          'Cette action effacera définitivement toutes les entrées enregistrées sur cet appareil. Elles ne pourront pas être récupérées. N’utilisez cette option que si vous ne pouvez pas retrouver votre clé de récupération.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Effacer et réinitialiser'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _storage.deleteAll();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _configured = false;
        _hasRecoveryKey = false;
        _unlocked = false;
        _entries = [];
        _failures = 0;
        _notice = 'Le coffre et toutes ses entrées ont été effacés.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Impossible de réinitialiser le coffre sécurisé : $error';
        });
      }
    }
  }

  Future<void> _saveEntries() async {
    try {
      await _storage.write(
        key: _entriesKey,
        value: jsonEncode(_entries.map((entry) => entry.toJson()).toList()),
      );
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Impossible d’enregistrer le coffre : $error');
      }
    }
  }

  Future<void> _openEditor({int? index}) async {
    final result = await showDialog<_EditorResult>(
      context: context,
      builder: (context) =>
          EntryEditorDialog(entry: index == null ? null : _entries[index]),
    );
    if (result == null || !mounted) return;

    setState(() {
      if (result.deleted && index != null) {
        _entries.removeAt(index);
      } else if (result.entry != null && index != null) {
        _entries[index] = result.entry!;
      } else if (result.entry != null) {
        _entries.add(result.entry!);
      }
    });
    await _saveEntries();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon coffre'),
        actions: [
          if (_unlocked)
            IconButton(
              tooltip: 'Verrouiller le coffre',
              onPressed: _lockVault,
              icon: const Icon(Icons.lock_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && !_configured
          ? _buildErrorScreen()
          : !_configured
          ? _buildPinGate(isSetup: true)
          : !_unlocked
          ? _buildPinGate(isSetup: false)
          : _buildVaultContents(),
      floatingActionButton: _unlocked
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter'),
            )
          : null,
    );
  }

  Widget _buildErrorScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadVault,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinGate({required bool isSetup}) {
    return PinGate(
      isSetup: isSetup,
      busy: _busy,
      failures: _failures,
      notice: _notice,
      error: _error,
      onSubmit: isSetup ? _createVault : _unlockVault,
      hasRecoveryKey: _hasRecoveryKey,
      onVerifyRecoveryKey: _verifyRecoveryKey,
      onRecover: _recoverVault,
      onReset: _resetVault,
    );
  }

  Widget _buildVaultContents() {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _entries.isEmpty
              ? const _EmptyVault()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => PasswordEntryCard(
                    entry: _entries[index],
                    onTap: () => _openEditor(index: index),
                  ),
                ),
        ),
      ),
    );
  }
}

class _RecoveryKeyDialog extends StatefulWidget {
  const _RecoveryKeyDialog({required this.recoveryKey});

  final String recoveryKey;

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _canClose = false;
  bool _copied = false;
  String? _copyError;

  Future<void> _copyRecoveryKey() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.recoveryKey));
      if (!mounted) return;
      setState(() {
        _copied = true;
        _copyError = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clé de récupération copiée.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _copyError = 'Impossible de copier la clé de récupération : $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canClose,
      child: AlertDialog(
        title: const Text('Conservez votre clé de récupération'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Cette clé est affichée une seule fois. Notez-la et gardez-la en lieu sûr, séparément de votre appareil. Elle permettra de définir un nouveau code principal.',
              ),
              const SizedBox(height: 16),
              SelectableText(
                widget.recoveryKey,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _copyRecoveryKey,
                icon: const Icon(Icons.copy),
                label: const Text('Copier la clé'),
              ),
              if (_copied) ...[
                const SizedBox(height: 8),
                const Text(
                  'Clé de récupération copiée.',
                  textAlign: TextAlign.center,
                ),
              ],
              if (_copyError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _copyError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              setState(() => _canClose = true);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) Navigator.of(context).pop();
              });
            },
            child: const Text('J’ai conservé ma clé'),
          ),
        ],
      ),
    );
  }
}

class PinGate extends StatefulWidget {
  const PinGate({
    required this.isSetup,
    required this.busy,
    required this.failures,
    required this.notice,
    required this.error,
    required this.onSubmit,
    required this.hasRecoveryKey,
    required this.onVerifyRecoveryKey,
    required this.onRecover,
    required this.onReset,
    super.key,
  });

  final bool isSetup;
  final bool busy;
  final int failures;
  final String? notice;
  final String? error;
  final ValueChanged<String> onSubmit;
  final bool hasRecoveryKey;
  final Future<String?> Function(String recoveryKey) onVerifyRecoveryKey;
  final Future<String?> Function(String recoveryKey, String newPin) onRecover;
  final VoidCallback onReset;

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  final _formKey = GlobalKey<FormState>();
  final _pinController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _obscurePin = true;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.isSetup && widget.failures >= 10) return;
    if (_formKey.currentState!.validate()) {
      widget.onSubmit(_pinController.text);
      _pinController.clear();
      _confirmationController.clear();
    }
  }

  Future<void> _openRecovery() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => _RecoveryDialog(
        onVerifyRecoveryKey: widget.onVerifyRecoveryKey,
        onRecover: widget.onRecover,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isSetup ? 'Créez votre code principal' : 'Bienvenue';
    const navy = Color(0xFF10243A);
    const paleBlue = Color(0xFFF2F6FB);
    final colors = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF8FAFD), Color(0xFFEAF0F7)],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Card(
              elevation: 10,
              shadowColor: navy.withValues(alpha: 0.12),
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(color: navy.withValues(alpha: 0.06)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 30, 26, 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 116,
                          height: 116,
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: paleBlue,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(color: const Color(0xFFE3EAF3)),
                          ),
                          child: Image.asset(
                            'assets/images/app_icon.png',
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(
                                  Icons.shield_rounded,
                                  size: 64,
                                  color: navy,
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: navy,
                              letterSpacing: -0.5,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        widget.isSetup
                            ? 'Ce code protégera l’accès à vos mots de passe. Choisissez au moins 6 caractères et mémorisez-le.'
                            : 'Entrez votre code principal pour accéder à vos mots de passe en toute sécurité.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.blueGrey.shade600,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _pinController,
                        autofocus: true,
                        obscureText: _obscurePin,
                        enabled:
                            !widget.busy &&
                            (widget.isSetup || widget.failures < 10),
                        textInputAction: widget.isSetup
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (!widget.isSetup) _submit();
                        },
                        decoration: InputDecoration(
                          labelText: 'Code principal',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            tooltip: _obscurePin
                                ? 'Afficher le code'
                                : 'Masquer le code',
                            onPressed: () =>
                                setState(() => _obscurePin = !_obscurePin),
                            icon: Icon(
                              _obscurePin
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFFE0E7EF),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: navy,
                              width: 1.7,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Saisissez votre code.';
                          }
                          if (widget.isSetup && value.length < 6) {
                            return 'Le code doit contenir au moins 6 caractères.';
                          }
                          return null;
                        },
                      ),
                      if (widget.isSetup) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmationController,
                          obscureText: _obscurePin,
                          enabled: !widget.busy,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: 'Confirmer le code',
                            prefixIcon: const Icon(
                              Icons.verified_user_outlined,
                            ),
                            filled: true,
                            fillColor: const Color(0xFFF8FAFC),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(
                                color: Color(0xFFE0E7EF),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(
                                color: navy,
                                width: 1.7,
                              ),
                            ),
                          ),
                          validator: (value) {
                            if (value != _pinController.text) {
                              return 'Les codes ne correspondent pas.';
                            }
                            return null;
                          },
                        ),
                      ],
                      if (widget.notice != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          widget.notice!,
                          style: TextStyle(color: colors.error),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (widget.error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          widget.error!,
                          style: TextStyle(color: colors.error),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (!widget.isSetup) ...[
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7E6),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.info_outline_rounded,
                                size: 19,
                                color: Color(0xFF946200),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  '${(10 - widget.failures).clamp(0, 10)} tentative${(10 - widget.failures).clamp(0, 10) == 1 ? '' : 's'} restante${(10 - widget.failures).clamp(0, 10) == 1 ? '' : 's'} avant la suspension du déverrouillage.',
                                  style: const TextStyle(
                                    color: Color(0xFF795500),
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 54,
                        child: FilledButton(
                          onPressed:
                              widget.busy ||
                                  (!widget.isSetup && widget.failures >= 10)
                              ? null
                              : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: navy,
                            foregroundColor: Colors.white,
                            elevation: 2,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: widget.busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      widget.isSetup
                                          ? Icons.shield_outlined
                                          : Icons.lock_open_rounded,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      widget.isSetup
                                          ? 'Créer mon coffre'
                                          : 'Déverrouiller',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      if (!widget.isSetup) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: widget.busy ? null : _openRecovery,
                          child: const Text('Code principal oublié ?'),
                        ),
                        TextButton(
                          onPressed: widget.busy ? null : widget.onReset,
                          child: const Text('Réinitialiser le coffre'),
                        ),
                      ],
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            size: 16,
                            color: Colors.blueGrey.shade400,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Votre sécurité est notre priorité',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.blueGrey.shade500,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog({
    required this.onVerifyRecoveryKey,
    required this.onRecover,
  });

  final Future<String?> Function(String recoveryKey) onVerifyRecoveryKey;
  final Future<String?> Function(String recoveryKey, String newPin) onRecover;

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _recoveryController = TextEditingController();
  final _pinController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _keyVerified = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _recoveryController.dispose();
    _pinController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    if (!_keyVerified) {
      final verificationError = await widget.onVerifyRecoveryKey(
        _recoveryController.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = verificationError;
        _keyVerified = verificationError == null;
      });
      return;
    }

    final error = await widget.onRecover(
      _recoveryController.text,
      _pinController.text,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Récupérer le coffre'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Vérifiez votre clé de récupération pour continuer.'),
              const SizedBox(height: 16),
              if (!_keyVerified) ...[
                TextFormField(
                  controller: _recoveryController,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Clé de récupération',
                    prefixIcon: Icon(Icons.key_outlined),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Saisissez votre clé de récupération.'
                      : null,
                ),
              ] else ...[
                const Row(
                  children: [
                    Icon(Icons.verified, color: Colors.green),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('Clé vérifiée. Choisissez un nouveau code.'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _pinController,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Nouveau code principal',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  validator: (value) {
                    if (value == null || value.length < 6) {
                      return 'Le code doit contenir au moins 6 caractères.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirmationController,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmer le nouveau code',
                    prefixIcon: Icon(Icons.verified_user_outlined),
                  ),
                  validator: (value) => value != _pinController.text
                      ? 'Les codes ne correspondent pas.'
                      : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _keyVerified ? 'Définir le nouveau code' : 'Vérifier la clé',
                ),
        ),
      ],
    );
  }
}

class _EmptyVault extends StatelessWidget {
  const _EmptyVault();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.key_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            'Votre coffre est vide',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Ajoutez vos premiers identifiants avec le bouton ci-dessous.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class PasswordEntryCard extends StatefulWidget {
  const PasswordEntryCard({
    required this.entry,
    required this.onTap,
    super.key,
  });

  final PasswordEntry entry;
  final VoidCallback onTap;

  @override
  State<PasswordEntryCard> createState() => _PasswordEntryCardState();
}

class _PasswordEntryCardState extends State<PasswordEntryCard> {
  bool _showPassword = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                child: Text(
                  widget.entry.title.isEmpty
                      ? '?'
                      : widget.entry.title.characters.first.toUpperCase(),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.entry.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (widget.entry.login.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.entry.login,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      _showPassword
                          ? widget.entry.password
                          : '•' * min(widget.entry.password.length, 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _showPassword
                    ? 'Masquer le mot de passe'
                    : 'Afficher le mot de passe',
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class EntryEditorDialog extends StatefulWidget {
  const EntryEditorDialog({this.entry, super.key});

  final PasswordEntry? entry;

  @override
  State<EntryEditorDialog> createState() => _EntryEditorDialogState();
}

class _EntryEditorDialogState extends State<EntryEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _loginController;
  late final TextEditingController _passwordController;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.entry?.title);
    _loginController = TextEditingController(text: widget.entry?.login);
    _passwordController = TextEditingController(text: widget.entry?.password);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      _EditorResult.saved(
        PasswordEntry(
          title: _titleController.text.trim(),
          login: _loginController.text.trim(),
          password: _passwordController.text,
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette entrée ?'),
        content: const Text('Cette action est définitive.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop(const _EditorResult.deleted());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.entry != null;
    return AlertDialog(
      title: Text(isEditing ? 'Modifier l’entrée' : 'Nouvelle entrée'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _titleController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Application ou site web',
                    prefixIcon: Icon(Icons.language),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Indiquez une application ou un site.'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _loginController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText:
                        'E-mail ou numéro de téléphone ou nom d’utilisateur',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Mot de passe',
                    prefixIcon: const Icon(Icons.key_outlined),
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword
                          ? 'Afficher le mot de passe'
                          : 'Masquer le mot de passe',
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                  validator: (value) => value == null || value.isEmpty
                      ? 'Saisissez le mot de passe.'
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (isEditing)
          TextButton.icon(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Supprimer'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _save, child: const Text('Enregistrer')),
      ],
    );
  }
}
