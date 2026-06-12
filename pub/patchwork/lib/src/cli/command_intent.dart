import '../target/target.dart';

sealed class CommandIntent {
  const CommandIntent();

  String get summary;
}

final class HelpIntent extends CommandIntent {
  const HelpIntent([this.command]);

  final String? command;

  @override
  String get summary => command == null ? 'help' : 'help $command';
}

final class PatchIntent extends CommandIntent {
  const PatchIntent.start(this.target) : commitSubject = null;

  const PatchIntent.commit(this.commitSubject) : target = null;

  final PubTarget? target;
  final PatchCommitSubject? commitSubject;

  bool get isCommit => commitSubject != null;

  @override
  String get summary {
    if (isCommit) {
      return 'patch --commit $commitSubject';
    }

    return 'patch $target';
  }
}

sealed class PatchCommitSubject {
  const PatchCommitSubject();
}

final class PatchCommitTarget extends PatchCommitSubject {
  const PatchCommitTarget(this.target);

  final PubTarget target;

  @override
  String toString() => target.toString();
}

final class PatchCommitDirectory extends PatchCommitSubject {
  const PatchCommitDirectory(this.path);

  final String path;

  @override
  String toString() => path;
}

final class ApplyIntent extends CommandIntent {
  const ApplyIntent([this.target]);

  final PubTarget? target;

  @override
  String get summary => target == null ? 'apply' : 'apply $target';
}

final class StatusIntent extends CommandIntent {
  const StatusIntent();

  @override
  String get summary => 'status';
}

final class DoctorIntent extends CommandIntent {
  const DoctorIntent();

  @override
  String get summary => 'doctor';
}
