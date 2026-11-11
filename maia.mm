#import "maia.h"
#import "engine.h"
#include <cmath>
#include <cstdlib>
#include <cstring>
#import <CoreML/CoreML.h>
#import <dlfcn.h>
#import <mach-o/getsect.h>
#import <vector>
#import <string>
#import <unordered_map>
#include <algorithm>

// ---- strength settings ----
// Elo is passed to the net as a raw integer and clamped to [0,5000] inside the
// model. The offset is pure calibration between rating pools, nothing else.
static const int kEloOffset = 100;
static const double kTempScale = 1.0; // 1.0 = the model's own distribution
static const int kHistPlanes = 8;     // 8 frames x 12 planes = 96

#define MAIA_DEBUG_DIST 0
#define MAIA_DEBUG_TOKENS 0

static double gForm = 0.0; // -1 cold game .. +1 hot game
static int gPly = 0;       // plies seen this game, from the history ring

static MLModel *gMaiaModel = nil;
static std::vector<std::string> gMoves;
static std::unordered_map<std::string, int> gMoveIdx;
static std::vector<std::string> gHist;
static bool gHaveRolled = false;

static std::string squareName(int sq) {
  char s[3];
  s[0] = 'a' + (sq & 7);
  s[1] = '1' + (sq >> 3);
  s[2] = '\0';
  return std::string(s);
}

static void buildMoveTables(void) {
  if (!gMoves.empty()) return;
  gMoves.resize(4352);
  for (int from = 0; from < 64; from++)
    for (int to = 0; to < 64; to++)
      gMoves[from * 64 + to] = squareName(from) + squareName(to);
  int idx = 4096;
  const char *pieces = "qrbn";
  for (int ff = 0; ff < 8; ff++)
    for (int ft = 0; ft < 8; ft++)
      for (int p = 0; p < 4; p++) {
        char s[6];
        s[0] = 'a' + ff;
        s[1] = '7';
        s[2] = 'a' + ft;
        s[3] = '8';
        s[4] = pieces[p];
        s[5] = '\0';
        gMoves[idx++] = std::string(s);
      }
  for (int i = 0; i < (int)gMoves.size(); i++) gMoveIdx[gMoves[i]] = i;
}

static std::string mirrorUci(const std::string &u) {
  std::string m = u;
  m[1] = '0' + (9 - (u[1] - '0'));
  m[3] = '0' + (9 - (u[3] - '0'));
  return m;
}

static bool parseFenBoard(const char *fen, char board[64], int *sideBlack) {
  for (int i = 0; i < 64; i++) board[i] = 0;
  const char *p = fen;
  int sq = 56;
  while (*p && *p != ' ') {
    char c = *p++;
    if (c == '/') {
      sq -= 16;
    } else if (c >= '1' && c <= '8') {
      sq += (c - '0');
    } else {
      if (sq >= 0 && sq < 64) board[sq] = c;
      sq++;
    }
  }
  while (*p == ' ') p++;
  *sideBlack = (*p == 'b') ? 1 : 0;
  return true;
}

// Board field of the start position. Independent of how many FEN fields the
// caller supplies, so a four-field FEN still works.
static const char kStartBoard[] = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR";

static bool isStartPos(const char *fen) {
  return strncmp(fen, kStartBoard, sizeof(kStartBoard) - 1) == 0;
}

// Roll a fresh form value once per game.
static void maybeRollForm(const char *fen) {
  if (isStartPos(fen) && (!gHaveRolled || gHist.size() > 1)) {
    gForm = ((double)arc4random_uniform(1000) / 1000.0) * 2.0 - 1.0;
    gHaveRolled = true;
    gHist.clear();
    gPly = 0;
  }
}

// Oldest first, newest last. Reset at the start of every game.
static void pushHistory(const char *fen) {
  if (isStartPos(fen)) {
    gHist.clear();
    gPly = 0;
  }
  if (!gHist.empty() && gHist.back() == fen) return;
  gHist.push_back(fen);
  if ((int)gHist.size() > kHistPlanes) gHist.erase(gHist.begin());
  gPly++;
}

// Record a ply without running inference. The host only calls MaiaGo on our own
// turn, so without this the ring is every other ply and every frame shares the
// current side to move.
extern "C" void MaiaNotePly(const char *fen) {
  if (!fen) return;
  maybeRollForm(fen);
  pushHistory(fen);
}

static int pieceType(char c) {
  switch (c) {
  case 'P': case 'p': return 1;
  case 'N': case 'n': return 2;
  case 'B': case 'b': return 3;
  case 'R': case 'r': return 4;
  case 'Q': case 'q': return 5;
  case 'K': case 'k': return 6;
  }
  return 0;
}

// The model concatenates history oldest-first along the channel axis, so the
// newest position is the LAST frame. Short history pads the front with the
// oldest available. Each frame is oriented to ITS OWN side to move, not the
// current one: upstream tokenizes per board, so the stack alternates.
static MLMultiArray *buildTokens(const char *fen, int sideBlack) {
  (void)sideBlack; // newest frame carries this by construction; kept for the caller
  pushHistory(fen);
  NSError *err = nil;
  MLMultiArray *arr = [[MLMultiArray alloc] initWithShape:@[@1, @64, @96] dataType:MLMultiArrayDataTypeFloat32 error:&err];
  if (!arr) return nil;
  float *dst = (float *)arr.dataPointer;
  memset(dst, 0, 64 * 96 * sizeof(float));
  int have = (int)gHist.size();
  if (have > kHistPlanes) have = kHistPlanes;
  int first = (int)gHist.size() - have;
  for (int f = 0; f < kHistPlanes; f++) {
    int rel = have - kHistPlanes + f;
    if (rel < 0) rel = 0;
    char board[64];
    int frameBlack = 0;
    parseFenBoard(gHist[first + rel].c_str(), board, &frameBlack);
    for (int sq = 0; sq < 64; sq++) {
      char c = board[sq];
      if (!c) continue;
      int t = pieceType(c);
      if (!t) continue;
      int isBlackPiece = (c >= 'a' && c <= 'z') ? 1 : 0;
      int tsq = frameBlack ? (sq ^ 56) : sq;
      int ch = (t - 1) + ((isBlackPiece ^ frameBlack) ? 6 : 0);
      dst[tsq * 96 + f * 12 + ch] = 1.0f;
    }
#if MAIA_DEBUG_TOKENS
    int lo = 0, hi = 0;
    for (int sq = 0; sq < 64; sq++) {
      for (int ch = 0; ch < 6; ch++) if (dst[sq * 96 + f * 12 + ch] != 0.0f) lo++;
      for (int ch = 6; ch < 12; ch++) if (dst[sq * 96 + f * 12 + ch] != 0.0f) hi++;
    }
    NSLog(@"maia tok f=%d frameBlack=%d planes0-5=%d planes6-11=%d", f, frameBlack, lo, hi);
#endif
  }
  return arr;
}

static MLMultiArray *scalarInt32(int v) {
  NSError *err = nil;
  MLMultiArray *a = [[MLMultiArray alloc] initWithShape:@[@1] dataType:MLMultiArrayDataTypeInt32 error:&err];
  if (!a) return nil;
  ((int32_t *)a.dataPointer)[0] = (int32_t)v;
  return a;
}

extern "C" bool MaiaLoad(const char *mlpackagePath) {
  if (gMaiaModel) return true;
  buildMoveTables();
  @autoreleasepool {
    NSString *path = [NSString stringWithUTF8String:mlpackagePath];
    NSURL *url = [NSURL fileURLWithPath:path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return false;
    NSError *err = nil;
    NSURL *compiled = [MLModel compileModelAtURL:url error:&err];
    if (!compiled || err) return false;
    MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
    cfg.computeUnits = MLComputeUnitsCPUOnly;
    MLModel *m = [MLModel modelWithContentsOfURL:compiled configuration:cfg error:&err];
    if (!m || err) return false;
    gMaiaModel = m;
  }
  return gMaiaModel != nil;
}

extern "C" bool MaiaAvailable(void) {
  return gMaiaModel != nil;
}

static bool MaiaLoadFromDir(NSString *dir) {
  @autoreleasepool {
    NSError *err = nil;
    NSURL *url = [NSURL fileURLWithPath:dir];
    NSURL *compiled = [MLModel compileModelAtURL:url error:&err];
    if (!compiled || err) return false;
    MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
    cfg.computeUnits = MLComputeUnitsCPUOnly;
    MLModel *m = [MLModel modelWithContentsOfURL:compiled configuration:cfg error:&err];
    if (!m || err) return false;
    gMaiaModel = m;
  }
  return gMaiaModel != nil;
}

// Rebuild the mlpackage from sections embedded in our own dylib and load it
// from the temp dir.
extern "C" bool MaiaLoadEmbedded(void) {
  if (gMaiaModel) return true;
  buildMoveTables();
  @autoreleasepool {
    Dl_info info;
    if (!dladdr((void *)&MaiaLoadEmbedded, &info) || !info.dli_fbase) return false;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
    unsigned long mfLen = 0, mdLen = 0, wLen = 0;
    uint8_t *mf = (uint8_t *)getsectiondata(mh, "__TEXT", "__maia_mfst", &mfLen);
    uint8_t *md = (uint8_t *)getsectiondata(mh, "__TEXT", "__maia_model", &mdLen);
    uint8_t *wg = (uint8_t *)getsectiondata(mh, "__TEXT", "__maia_wghts", &wLen);
    if (!mf || !md || !wg || mfLen == 0 || mdLen == 0 || wLen == 0) return false;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"maia3_5m.mlpackage"];
    [fm removeItemAtPath:dir error:nil];
    NSString *weightsDir = [dir stringByAppendingPathComponent:@"Data/com.apple.CoreML/weights"];
    if (![fm createDirectoryAtPath:weightsDir withIntermediateDirectories:YES attributes:nil error:nil]) return false;

    BOOL ok = [fm createFileAtPath:[dir stringByAppendingPathComponent:@"Manifest.json"] contents:[NSData dataWithBytes:mf length:mfLen] attributes:nil];
    ok = ok && [fm createFileAtPath:[[dir stringByAppendingPathComponent:@"Data/com.apple.CoreML"] stringByAppendingPathComponent:@"model.mlmodel"] contents:[NSData dataWithBytes:md length:mdLen] attributes:nil];
    ok = ok && [fm createFileAtPath:[weightsDir stringByAppendingPathComponent:@"weight.bin"] contents:[NSData dataWithBytes:wg length:wLen] attributes:nil];
    if (!ok) return false;

    return MaiaLoadFromDir(dir);
  }
}

extern "C" void MaiaGo(const char *fen, int selfElo, int oppoElo, MaiaResultBlock done) {
  MaiaResult res;
  memset(&res, 0, sizeof(res));
  res.ok = false;

  if (!gMaiaModel) {
    if (done) done(res);
    return;
  }

  maybeRollForm(fen);

  int modelElo = selfElo - kEloOffset;
  if (modelElo < 600) modelElo = 600;
  if (modelElo > 2600) modelElo = 2600;
  int modelOppo = oppoElo - kEloOffset;
  if (modelOppo < 600) modelOppo = 600;
  if (modelOppo > 2600) modelOppo = 2600;

  int sideBlack = 0;
  {
    char b[64];
    parseFenBoard(fen, b, &sideBlack);
  }

  char legalBuf[256 * 6];
  int legalCount = StockfishLegalMoves(fen, legalBuf, 256);
  if (legalCount <= 0) {
    if (done) done(res);
    return;
  }

  @autoreleasepool {
    MLMultiArray *tokens = buildTokens(fen, sideBlack);
    MLMultiArray *se = scalarInt32(modelElo);
    MLMultiArray *oe = scalarInt32(modelOppo);
    if (!tokens || !se || !oe) {
      if (done) done(res);
      return;
    }

    NSDictionary *feats = @{
      @"tokens": [MLFeatureValue featureValueWithMultiArray:tokens],
      @"self_elo": [MLFeatureValue featureValueWithMultiArray:se],
      @"oppo_elo": [MLFeatureValue featureValueWithMultiArray:oe],
    };

    NSError *err = nil;
    MLDictionaryFeatureProvider *prov = [[MLDictionaryFeatureProvider alloc] initWithDictionary:feats error:&err];
    if (!prov || err) {
      if (done) done(res);
      return;
    }

    id<MLFeatureProvider> out = [gMaiaModel predictionFromFeatures:prov error:&err];
    if (!out || err) {
      if (done) done(res);
      return;
    }

    MLMultiArray *moveLogits = [out featureValueForName:@"move_logits"].multiArrayValue;
    MLMultiArray *valueLogits = [out featureValueForName:@"value_logits"].multiArrayValue;
    if (!moveLogits) {
      if (done) done(res);
      return;
    }

    struct Cand {
      double logit;
      std::string uci;
      double prob;
    };
    std::vector<Cand> cands;
    for (int i = 0; i < legalCount; i++) {
      std::string uci(&legalBuf[i * 6]);
      std::string modelUci = sideBlack ? mirrorUci(uci) : uci;
      auto it = gMoveIdx.find(modelUci);
      if (it == gMoveIdx.end()) continue;
      double v = [[moveLogits objectAtIndexedSubscript:it->second] doubleValue];
      cands.push_back({v, uci, 0.0});
    }
    if (cands.empty()) {
      if (done) done(res);
      return;
    }

    std::sort(cands.begin(), cands.end(), [](const Cand &a, const Cand &b) { return a.logit > b.logit; });

    int total = (int)cands.size();

    // Reference sampler: softmax over the full masked vocabulary at flat 1.0.
    // No form term, no opening boost.
    double T = kTempScale;
    if (T < 0.05) T = 0.05;

    double mx = cands[0].logit, sum = 0;
    for (int i = 0; i < total; i++) {
      cands[i].prob = exp((cands[i].logit - mx) / T);
      sum += cands[i].prob;
    }
    if (sum <= 0) sum = 1.0;
    for (int i = 0; i < total; i++) cands[i].prob /= sum;

#if MAIA_DEBUG_DIST
    NSMutableString *dbg = [NSMutableString string];
    int dn = total < 6 ? total : 6;
    for (int i = 0; i < dn; i++) [dbg appendFormat:@"%s=%.3f(%.2f) ", cands[i].uci.c_str(), cands[i].prob, cands[i].logit];
    NSLog(@"maia elo=%d ply=%d form=%.2f T=%.2f n=%d :: %@", modelElo, gPly, gForm, T, total, dbg);
#endif

    int pick = 0;
    double r = (double)arc4random_uniform(1000000) / 1000000.0, acc = 0;
    for (int i = 0; i < total; i++) {
      acc += cands[i].prob;
      if (r <= acc) {
        pick = i;
        break;
      }
    }
    if (pick >= total) pick = total - 1;

    if (pick > 0) std::rotate(cands.begin(), cands.begin() + pick, cands.begin() + pick + 1);

    int n = total;
    if (n > 4) n = 4;
    res.count = n;
    for (int i = 0; i < n; i++) {
      std::strncpy(res.moves[i], cands[i].uci.c_str(), 7);
      res.moves[i][7] = '\0';
      res.policy[i] = cands[i].prob;
    }
    std::strncpy(res.move, cands[0].uci.c_str(), 7);
    res.move[7] = '\0';

    double stmScore = 0;
    if (valueLogits && valueLogits.count >= 3) {
      double l[3];
      l[0] = [[valueLogits objectAtIndexedSubscript:0] doubleValue];
      l[1] = [[valueLogits objectAtIndexedSubscript:1] doubleValue];
      l[2] = [[valueLogits objectAtIndexedSubscript:2] doubleValue];
      double vmx = fmax(l[0], fmax(l[1], l[2]));
      double e0 = exp(l[0] - vmx), e1 = exp(l[1] - vmx), e2 = exp(l[2] - vmx);
      double s2 = e0 + e1 + e2;
      double lossP = e0 / s2, winP = e2 / s2;
      res.winPct = winP * 100.0;
      stmScore = (winP - lossP) * 4.0;
    }
    res.whiteEval = sideBlack ? -stmScore : stmScore;
    res.ok = true;
  }

  if (done) done(res);
}
