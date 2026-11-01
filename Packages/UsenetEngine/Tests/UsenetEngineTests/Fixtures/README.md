These fixtures contain only a synthetic 8192-byte payload named small.mp4. Each payload byte is its position modulo 256. They contain no movie content and are not playable video samples.

legacy.part*.rar was generated with the official RAR 6.23 utility using -ma4 -m0 -v4k -ep.
small.part*.rar was generated with the official current RAR utility using -m0 -v4k -ep and the RAR5 format.

The utility is not included. These independent archive fixtures exercise the reader against actual stored multi-volume output.

rar4-file/rar4-header and rar5-file/rar5-header contain a synthetic 8216-byte payload named Movie.mp4. It starts with a 24-byte ftyp/isom header followed by 8192 bytes whose value is their position modulo 256. These are not playable movie content. They use -m0 -psecret or -m0 -hpsecret, with -v4k -ep (RAR4 adds -ma4 via RAR 6.23). Their volume boundaries deliberately split AES blocks.

rar4-unicode and rar5-unicode use header encryption and the fixture-only password `long-password-` followed by six repetitions of `épisode🌙-`. They exercise historical RAR3 wide-character handling and long-password derivation independently of the implementation.

season-pack.part*.rar contains two copies of the same synthetic payload named Show.S01E01.mp4 and Show.S01E02.mp4. It uses RAR5 header encryption with the fixture-only password `secret`, stored mode and 4 KiB volumes.
