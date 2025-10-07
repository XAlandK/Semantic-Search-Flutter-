import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

// Configuration constants
class AppConfig {
  static const String geminiApiKey = ''; // Move to env file
  static const String supabaseUrl = '';
  static const String supabaseAnonKey = ''; // Move to env file
  static const String embeddingModel = 'models/text-embedding-004';
  static const String matchFunction = 'match_contents';
}

// Service layer for API calls
class EmbeddingService {
  static Future<List<double>> generateEmbedding(String text) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('Text cannot be empty');
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'text-embedding-004:embedContent?key=${AppConfig.geminiApiKey}',
    );

    final body = {
      'model': AppConfig.embeddingModel,
      'content': {
        'parts': [
          {'text': text},
        ],
      },
    };

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final embedding = data['embedding']['values'] as List;
        return embedding.map<double>((e) => (e as num).toDouble()).toList();
      } else {
        throw Exception(
          'Failed to generate embedding: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Embedding generation error: $e');
      rethrow;
    }
  }
}

// Database service
class ContentRepository {
  final SupabaseClient _client;

  ContentRepository(this._client);

  Future<void> insertContent({
    required String text,
    required List<double> embedding,
  }) async {
    try {
      await _client.from('contents').insert({
        'text': text,
        'embedding': embedding,
      });
      debugPrint('Content inserted successfully');
    } catch (e) {
      debugPrint('Insert error: $e');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> searchByMeaning({
    required String query,
    double threshold = 0.6,
    int matchCount = 5,
  }) async {
    debugPrint('Searching for: $query');

    final embedding = await EmbeddingService.generateEmbedding(query);

    if (embedding.isEmpty) {
      throw Exception('Generated embedding is empty');
    }

    debugPrint('Embedding: ${embedding.length} dimensions');

    try {
      final response = await _client
          .rpc(
            AppConfig.matchFunction,
            params: {
              'query_embedding': embedding,
              'match_threshold': threshold,
              'match_count': matchCount,
            },
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Search timed out'),
          );

      debugPrint('Response received: ${response.runtimeType}');

      final data = response as List<dynamic>? ?? [];
      return List<Map<String, dynamic>>.from(
        data.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (e) {
      debugPrint('Search error: $e');
      rethrow;
    }
  }
}

// Main entry point
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Semantic Search',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const SemanticSearchPage(),
    );
  }
}

// Main page
class SemanticSearchPage extends StatefulWidget {
  const SemanticSearchPage({super.key});

  @override
  State<SemanticSearchPage> createState() => _SemanticSearchPageState();
}

class _SemanticSearchPageState extends State<SemanticSearchPage> {
  late final TextEditingController _controller;
  late final ContentRepository _repository;

  List<Map<String, dynamic>> _results = [];
  bool _isLoading = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _repository = ContentRepository(Supabase.instance.client);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSearch() async {
    final query = _controller.text.trim();
    
    if (query.isEmpty) {
      _showMessage('Please enter a search query');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = null;
      _results = [];
    });

    try {
      final data = await _repository.searchByMeaning(query: query);
      
      setState(() {
        _results = data;
        _isLoading = false;
        if (data.isEmpty) {
          _statusMessage = 'No matching contents found';
        }
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Search failed: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  Future<void> _handleAddContent() async {
    final text = _controller.text.trim();
    
    if (text.isEmpty) {
      _showMessage('Please enter content to add');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = null;
    });

    try {
      final embedding = await EmbeddingService.generateEmbedding(text);
      
      if (embedding.isEmpty) {
        throw Exception('Failed to generate embedding');
      }

      await _repository.insertContent(text: text, embedding: embedding);

      setState(() {
        _statusMessage = 'Content added successfully!';
        _isLoading = false;
        _controller.clear();
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Failed to add content: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  void _showMessage(String message) {
    setState(() => _statusMessage = message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Semantic Search'),
        elevation: 2,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildSearchInput(),
            const SizedBox(height: 12),
            _buildActionButtons(),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              _buildStatusMessage(),
            ],
            const SizedBox(height: 20),
            Expanded(child: _buildResultsList()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchInput() {
    return TextField(
      controller: _controller,
      decoration: const InputDecoration(
        hintText: 'Enter content or search query',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.search),
      ),
      onSubmitted: (_) => _handleSearch(),
      enabled: !_isLoading,
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _handleSearch,
            icon: const Icon(Icons.search),
            label: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Search'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _handleAddContent,
            icon: const Icon(Icons.add),
            label: const Text('Add Content'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusMessage() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.blue.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusMessage!,
              style: TextStyle(color: Colors.blue.shade900),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsList() {
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'No results yet',
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        final text = item['text'] ?? 'No text available';
        final similarity = (item['similarity'] ?? 0.0) as num;
        final similarityPercent = (similarity * 100).toStringAsFixed(1);

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 2,
          child: ListTile(
            title: Text(text),
            subtitle: Text('Similarity: $similarityPercent%'),
            trailing: CircularProgressIndicator(
              value: similarity.toDouble(),
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(
                _getSimilarityColor(similarity.toDouble()),
              ),
            ),
          ),
        );
      },
    );
  }

  Color _getSimilarityColor(double similarity) {
    if (similarity >= 0.8) return Colors.green;
    if (similarity >= 0.6) return Colors.orange;
    return Colors.red;
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);

  @override
  String toString() => message;
}
