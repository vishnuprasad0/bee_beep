const int beeBeepLatestProtocolVersion = 95;
const int beeBeepSecureLevel4ProtocolVersion = 90;

const int beeBeepUtcTimestampProtocolVersion = 68;

const int beeBeepEncryptedDataBlockSize = 16;
const int beeBeepEncryptionKeyBits = 256;

const String beeBeepServiceType = '_beebeep._tcp';

const int beeBeepUdpDiscoveryPort = 6475;
const String beeBeepUdpDiscoveryMessage = 'BEEBEEP_DISCOVER';
const String beeBeepUdpResponseMessage = 'BEEBEEP_HERE';

const String beeBeepProtocolFieldSeparator = '\u2029';
const String beeBeepDataFieldSeparator = '\u2028';

const int beeBeepIdInvalid = 0;
const int beeBeepIdLocalUser = 1;
const int beeBeepIdDefaultChat = 2;

const int beeBeepIdHelloMessage = 15;

enum BeeBeepMessageType {
  undefined,
  beep,
  hello,
  ping,
  pong,
  chat,
  system,
  user,
  file,
  share,
  group,
  folder,
  read,
  hive,
  shareBox,
  shareDesktop,
  buzz,
  test,
  help,
  received,
}

enum BeeBeepMessageFlag {
  private,
  userWriting,
  userStatus,
  create,
  userVCard,
  refused,
  list,
  request,
  groupChat,
  delete,
  auto,
  important,
  voiceMessage,
  encryptionDisabled,
  compressed,
  delayed,
  sourceCode,
}

int beeBeepFlagBit(BeeBeepMessageFlag flag) => 1 << flag.index;

String beeBeepHeaderForType(BeeBeepMessageType type) {
  switch (type) {
    case BeeBeepMessageType.beep:
      return 'BEE-BEEP';
    case BeeBeepMessageType.ping:
      return 'BEE-PING';
    case BeeBeepMessageType.pong:
      return 'BEE-PONG';
    case BeeBeepMessageType.chat:
      return 'BEE-CHAT';
    case BeeBeepMessageType.received:
      return 'BEE-RECV';
    case BeeBeepMessageType.read:
      return 'BEE-READ';
    case BeeBeepMessageType.buzz:
      return 'BEE-BUZZ';
    case BeeBeepMessageType.hello:
      return 'BEE-CIAO';
    case BeeBeepMessageType.system:
      return 'BEE-SYST';
    case BeeBeepMessageType.user:
      return 'BEE-USER';
    case BeeBeepMessageType.file:
      return 'BEE-FILE';
    case BeeBeepMessageType.share:
      return 'BEE-FSHR';
    case BeeBeepMessageType.group:
      return 'BEE-GROU';
    case BeeBeepMessageType.folder:
      return 'BEE-FOLD';
    case BeeBeepMessageType.shareBox:
      return 'BEE-SBOX';
    case BeeBeepMessageType.hive:
      return 'BEE-HIVE';
    case BeeBeepMessageType.shareDesktop:
      return 'BEE-DESK';
    case BeeBeepMessageType.test:
      return 'BEE-TEST';
    case BeeBeepMessageType.help:
      return 'BEE-HELP';
    case BeeBeepMessageType.undefined:
      return 'BEE-UNKN';
  }
}

BeeBeepMessageType beeBeepTypeFromHeader(String header) {
  switch (header) {
    case 'BEE-BEEP':
      return BeeBeepMessageType.beep;
    case 'BEE-PING':
      return BeeBeepMessageType.ping;
    case 'BEE-PONG':
      return BeeBeepMessageType.pong;
    case 'BEE-USER':
      return BeeBeepMessageType.user;
    case 'BEE-CHAT':
      return BeeBeepMessageType.chat;
    case 'BEE-RECV':
      return BeeBeepMessageType.received;
    case 'BEE-READ':
      return BeeBeepMessageType.read;
    case 'BEE-BUZZ':
      return BeeBeepMessageType.buzz;
    case 'BEE-CIAO':
      return BeeBeepMessageType.hello;
    case 'BEE-SYST':
      return BeeBeepMessageType.system;
    case 'BEE-FILE':
      return BeeBeepMessageType.file;
    case 'BEE-FSHR':
      return BeeBeepMessageType.share;
    case 'BEE-GROU':
      return BeeBeepMessageType.group;
    case 'BEE-FOLD':
      return BeeBeepMessageType.folder;
    case 'BEE-SBOX':
      return BeeBeepMessageType.shareBox;
    case 'BEE-HIVE':
      return BeeBeepMessageType.hive;
    case 'BEE-DESK':
      return BeeBeepMessageType.shareDesktop;
    case 'BEE-TEST':
      return BeeBeepMessageType.test;
    case 'BEE-HELP':
      return BeeBeepMessageType.help;
    default:
      return BeeBeepMessageType.undefined;
  }
}
