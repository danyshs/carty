/// [PullRequest] — a proposal to merge one branch into another, modelled as
/// first-class *graph data* so the whole review flow stays on-device.
///
/// A PR is just metadata over the merge engine: it names a `source` and `target`
/// branch and, when applied, runs the same deterministic three-way [merge] the
/// repository uses. It exists so a future editor UI can show "branch X wants to
/// merge into Y", preview the resulting graph, and surface conflicts before any
/// history is written — no network, no server, no remote review service.
library;

import 'repository.dart';

class PullRequest {
  final String title;
  final String sourceBranch;
  final String targetBranch;

  PullRequest({
    required this.title,
    required this.sourceBranch,
    required this.targetBranch,
  }) {
    assert(title.isNotEmpty, 'PR title must be non-empty');
    assert(sourceBranch != targetBranch,
        'a PR cannot merge a branch into itself ($sourceBranch)');
  }

  /// Applies the PR against [repo]: checks out [targetBranch], merges
  /// [sourceBranch] in, and returns the outcome. A conflicted outcome writes no
  /// history (see [MapRepository.merge]), so an unmergeable PR is observable
  /// without corrupting the target branch.
  MergeOutcome apply(MapRepository repo, {required int timestampMillis}) {
    repo.checkout(targetBranch);
    return repo.merge(
      sourceBranch,
      timestampMillis: timestampMillis,
      message: 'PR: $title',
    );
  }

  @override
  String toString() =>
      'PullRequest("$title": $sourceBranch -> $targetBranch)';
}
