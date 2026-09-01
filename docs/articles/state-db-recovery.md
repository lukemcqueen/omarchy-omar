# Article: The Day the Agent Forgot — SQLite Corruption on a Dying Disk

*Gleaned from a real incident: a 2015 MacBook whose disk was dying mid-session, and the
agent's memory — 430,000+ conversation messages — nearly went with it.*

## The symptom

One morning, the agent started replying with:

> ⚠️ No reply: the turn was stopped because session storage could not be written
> (the transcript would have been lost on restart).

The natural assumption is **full disk**. Check `df -h` — 37 GB free. Inodes fine.
Permissions fine. The database file exists and opens. So why can't it write?

## The real story: three separate bugs stacking

### 1. The disk is dying (hardware)

The kernel log had the smoking gun, hours earlier:

```
ata1.00: failed command: WRITE DMA EXT
I/O error, dev sda, sector 108400672 op 0x1:(WRITE)
EXT4-fs warning: I/O error 10 writing to inode 6686161
```

The chain: an IOMMU (DMAR) fault on the SATA controller → host bus error → the write
command fails → the link resets. **Hundreds** of these per boot, in bursts (02:46,
03:27, 04:27, 06:16). The old Apple SSD was failing — and writes were landing all over
a 1000-extent filesystem.

### 2. A torn write corrupts the transcript table

The agent's memory is one SQLite file (`state.db`, ~1.9 GB) with full-text search.
One of those failed writes tore a ~100-page hole right through the `messages` table.
`PRAGMA integrity_check` found it:

```
btreeInitPage() returns error code 11   (hundreds of pages, contiguous 100743–100864)
```

A torn write = some pages from the old version, some from the new — a corrupt btree.
The agent could still *read* old messages (they're in the uncorrupted pages) but any
*append* near the hole failed. And SQLite doesn't notice until it walks into the hole.

### 3. The retry net misses non-SQLite exceptions

The write path had a retry wrapper — but it only catches `sqlite3.Error` subclasses.
The failing call raised a plain `SystemError: returned NULL without setting an
exception` (a C-level hiccup in the driver). That escaped the retry net instantly and
aborted the turn: "transcript would have been lost" — correctly refusing to continue
rather than silently drop history.

## The fix: recover, don't panic

```bash
hermes sessions recover --source ~/.hermes/state.db \
  --output ~/.hermes/state.db.recovered --allow-partial
```

`--allow-partial` is the key flag: it salvages everything it can read and skips the
damaged rows instead of aborting. Result: **431,255 of ~434,000 messages recovered** —
only the ~3,100 messages sitting in the torn pages were lost (one specific session's
history). The recovered file is a *new* database; the corrupt original stays untouched
as evidence. Swap it in, restart the gateway, done.

## The lessons

1. **"Full disk" is a guess, not a diagnosis.** The error message says *often* full
   disk — but the real cause was hardware. Check `journalctl -k` for `I/O error` and
   `ata` lines before blaming storage space.
2. **A corrupt DB and a full disk look identical from the app layer.** Both present as
   "cannot write". The difference lives in kernel logs and `integrity_check`.
3. **Corruption on a dying disk is a *migration* problem, not a repair problem.** We
   recovered the data, but the disk kept failing. The durable fix was replacing the
   hardware — the machine now runs on a new NVMe with zero errors.
4. **Keep the corrupt file.** It's evidence; you may need it to explain what happened
   or to re-attempt recovery with a newer tool.
5. **`--allow-partial` is your friend.** A strict recovery that aborts on the first bad
   page saves nothing. Salvage-first, verify-after, swap-last.

## Related

- Hardware-level: old SATA drives with IOMMU/DMAR faults → new NVMe
- App-level: retry nets should catch the widest exception family, not just the
  documented one
- [`../03-hermes-first-class.md`](../03-hermes-first-class.md) — keeping the DB and
  gateway healthy as system services
