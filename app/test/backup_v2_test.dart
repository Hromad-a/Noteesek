import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/features/backup/v2/backup_v2.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

BackupInput _sample() => BackupInput(
      app: '1.0.0+1',
      labels: [BackupLabelInput(id: 'l1', name: 'Travel', color: 'mint')],
      notebooks: [BackupNotebookInput(id: 'nb1', name: 'Trips')],
      notes: [
        BackupNoteInput(
          id: 'n1',
          type: 'text',
          title: 'Packing',
          body: 'socks, **passport**, charger',
          color: 'lavender',
          labelIds: ['l1'],
          notebookId: 'nb1',
          attachments: [
            BackupAttachmentInput(id: 'a1', bytes: _bytes([1, 2, 3, 4, 5])),
          ],
        ),
        BackupNoteInput(
          id: 'n2',
          type: 'checklist',
          title: 'Todo',
          items: [
            BackupItemInput(id: 'i1', text: 'passport', checked: true),
            BackupItemInput(id: 'i2', text: 'tickets'),
          ],
          // same bytes as a1 → must dedup to one blob
          attachments: [
            BackupAttachmentInput(id: 'a2', bytes: _bytes([1, 2, 3, 4, 5])),
          ],
        ),
      ],
    );

void main() {
  test('round-trips notes, labels, notebooks, and attachment bytes', () async {
    final zip = await writeBackupV2(_sample());
    final r = BackupV2Reader.read(zip);

    expect(r.manifest['format'], 2);
    expect(r.notes.map((n) => n['id']), containsAll(['n1', 'n2']));
    expect(r.labels.single['name'], 'Travel');
    expect(r.notebooks.single['name'], 'Trips');

    final n1 = r.noteRecord('n1')!;
    expect(n1['title'], 'Packing');
    expect(n1['labelIds'], ['l1']);
    final sha = (n1['attachments'] as List).first['sha256'] as String;
    expect(r.attachmentBytes(sha, 'jpg'), _bytes([1, 2, 3, 4, 5]));

    final n2 = r.noteRecord('n2')!;
    expect((n2['items'] as List).length, 2);
  });

  test('attachments are content-addressed and deduplicated by hash', () async {
    final zip = await writeBackupV2(_sample());
    final archive = ZipDecoder().decodeBytes(zip);
    final attachmentFiles =
        archive.files.where((f) => f.name.startsWith('attachments/')).toList();
    // n1.a1 and n2.a2 share identical bytes → exactly one stored blob.
    expect(attachmentFiles.length, 1);
    expect(attachmentFiles.single.name, matches(r'^attachments/[0-9a-f]{64}\.jpg$'));
    expect(r0(zip).manifest['counts']['attachments'], 1);
  });

  test('a clean backup reports no damaged entries', () async {
    final zip = await writeBackupV2(_sample());
    expect(BackupV2Reader.read(zip).damagedEntries(), isEmpty);
  });

  test('fault isolation: one corrupt note is flagged but the rest survive',
      () async {
    final zip = await writeBackupV2(_sample());
    // Corrupt only notes/n1.json, re-zip.
    final archive = ZipDecoder().decodeBytes(zip);
    final tampered = Archive();
    for (final f in archive.files) {
      if (f.name == 'notes/n1.json') {
        final bad = _bytes([..._asList(f), 0x21]); // flip the bytes
        tampered.addFile(ArchiveFile(f.name, bad.length, bad));
      } else {
        tampered.addFile(ArchiveFile(f.name, f.size, _asList(f)));
      }
    }
    final r = BackupV2Reader.read(
        Uint8List.fromList(ZipEncoder().encode(tampered)));

    expect(r.damagedEntries(), ['notes/n1.json']);
    expect(r.noteRecord('n1'), isNull, reason: 'damaged note not returned');
    expect(r.noteRecord('n2'), isNotNull, reason: 'other notes still import');
  });

  test('manifest.bak.json is used when the primary manifest is corrupt',
      () async {
    final zip = await writeBackupV2(_sample());
    final archive = ZipDecoder().decodeBytes(zip);
    final tampered = Archive();
    for (final f in archive.files) {
      if (f.name == 'manifest.json') {
        final junk = utf8.encode('{ not valid json');
        tampered.addFile(ArchiveFile(f.name, junk.length, junk));
      } else {
        tampered.addFile(ArchiveFile(f.name, f.size, _asList(f)));
      }
    }
    final r = BackupV2Reader.read(
        Uint8List.fromList(ZipEncoder().encode(tampered)));
    // Falls back to the duplicate → still fully readable.
    expect(r.notes.map((n) => n['id']), containsAll(['n1', 'n2']));
  });

  test('reading a non-v2 payload throws BackupV2FormatException', () {
    final notAZip = Uint8List.fromList(utf8.encode('{"format":1}'));
    expect(() => BackupV2Reader.read(notAZip), throwsA(anything));
  });

  test('image backgrounds round-trip: bytes, options, and note reference',
      () async {
    final zip = await writeBackupV2(BackupInput(
      labels: const [],
      notebooks: const [],
      backgrounds: [
        BackupBackgroundInput(
          id: 'bg1',
          name: 'Beach',
          bytes: _bytes([9, 8, 7, 6]),
          opacity: 0.8,
          overlayColor: '#000000',
          overlayOpacity: 0.3,
          fit: 'contain',
          repeat: 'repeatX',
          scale: 1.5,
        ),
      ],
      notes: [
        BackupNoteInput(id: 'n1', type: 'text', background: 'bg1'),
      ],
    ));
    final r = BackupV2Reader.read(zip);

    expect(r.noteRecord('n1')!['background'], 'bg1');

    final bg = r.backgrounds.single;
    expect(bg['id'], 'bg1');
    expect(bg['opacity'], 0.8);
    expect(bg['overlayColor'], '#000000');
    expect(bg['fit'], 'contain');
    expect(bg['repeat'], 'repeatX');
    expect(bg['scale'], 1.5);
    expect(r.backgroundBytes(bg['sha256'] as String, bg['ext'] as String),
        _bytes([9, 8, 7, 6]));
  });
}

List<int> _asList(ArchiveFile f) => List<int>.from(f.content as List<int>);
BackupV2Reader r0(Uint8List zip) => BackupV2Reader.read(zip);
