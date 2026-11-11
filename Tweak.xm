#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
#import "engine.h"
#import "maia.h"

extern "C" void MaiaNotePly(const char *fen);

#define CH_ACCENT [UIColor colorWithRed:0.49 green:0.66 blue:0.32 alpha:1.0]

#define PREF_ELO     @"ChessAssist_ELO"
#define PREF_ENABLED @"ChessAssist_Enabled"
#define PREF_SHOWN   @"ChessAssist_CreditShown"
#define PREF_CREDIT2 @"ChessAssist_CreditShown2"
#define PREF_WINPCT  @"ChessAssist_WinPct"
#define PREF_ARROWS  @"ChessAssist_ArrowCount"
#define PREF_ALPHA   @"ChessAssist_ArrowAlpha"
#define PREF_THICK   @"ChessAssist_ArrowThick"
#define PREF_EVALCLR @"ChessAssist_ArrowEvalColor"
#define PREF_QUALITY @"ChessAssist_TrackQuality"
#define PREF_EVALLBL @"ChessAssist_EvalLabels"
#define PREF_EVALBAR @"ChessAssist_EvalBar"
#define PREF_USEMAIA @"ChessAssist_UseMaia"
#define PREF_AUTOPLAY @"ChessAssist_AutoPlay"
#define PREF_APDELAY  @"ChessAssist_AutoPlayDelay"
#define PREF_APJITEN  @"ChessAssist_AutoPlayJitterEnabled"
#define PREF_APJITRNG @"ChessAssist_AutoPlayJitterRange"
#define PREF_AP2ND    @"ChessAssist_AutoPlaySecondBest"
#define PREF_AP2NDPCT @"ChessAssist_AutoPlaySecondBestPct"
#define DEFAULT_ELO  800

static NSInteger gElo     = DEFAULT_ELO;
static BOOL      gEnabled = YES;
static NSString *gLastFen = nil;
static NSString *gPendingFen = nil;
static BOOL      gFetching = NO;
static NSDate   *gLastFetch = nil;
static __weak id gOnlineGame = nil;
static NSDate   *gLoadTime = nil;
static NSInteger gMyColor = -1;
static double    gLastEval = 0;
static BOOL      gHasEval  = NO;
static int       gForcedFlip = -1;
static BOOL      gShowWinPct = NO;
static NSInteger gArrowCount = 1;
static CGFloat   gArrowAlpha = 0.7;
static CGFloat   gArrowThick = 1.0;
static BOOL      gArrowEvalColor = YES;
static BOOL      gTrackQuality = YES;
static NSString *gQualFen = nil;
static double    gQualWhiteEval = 0;
static BOOL      gQualHave = NO;
static NSString *gLastQualDone = nil;
static double    gAccSum = 0;
static int       gAccCount = 0;
static NSString *gLastMoveQuality = nil;
static BOOL      gPuzzleCtx = NO;

enum { Q_BRILLIANT, Q_GREAT, Q_BEST, Q_EXCELLENT, Q_GOOD, Q_INACC, Q_MISS, Q_MISTAKE, Q_BLUNDER, Q_COUNT };
static int    gQ[Q_COUNT] = {0};
static double gQual2ndWhite = 0;
static BOOL   gQualHave2nd = NO;
static BOOL gShowEvalLabels = YES;
static BOOL gUseMaia = NO;
static BOOL gAutoPlay = NO;
static double gAutoPlayDelay = 0.15;
static BOOL gAutoPlayJitterEnabled = NO;
static double gAutoPlayJitterRange = 1.0;
static BOOL gAutoPlaySecondBest = NO;
static NSInteger gAutoPlaySecondBestPct = 10;
static NSString *gLastAutoPlayed = nil;
static NSMutableString *gUciSeq = nil;
static NSString *gPgnStartFen = nil;
static BOOL gShowEvalBar = YES;
static BOOL gBarHave = NO;
static double gBarWhiteEval = 0;
static BOOL gBarIsMate = NO;
static int gBarMateWhite = 0;
static BOOL gSkipNextTap = NO;

static NSMutableArray *gLog;
static NSString *gLogPath = nil;
static void dbg(NSString *msg) {
    if (!gLog) gLog = [NSMutableArray array];
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], msg];
    [gLog addObject:line];
    while (gLog.count > 200) [gLog removeObjectAtIndex:0];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
                    stringByAppendingPathComponent:@"chessassist.log"];
        [@"" writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    });
    if (gLogPath) {
        FILE *fp = fopen(gLogPath.fileSystemRepresentation, "a");
        if (fp) { fputs([line UTF8String], fp); fputc('\n', fp); fclose(fp); }
    }
}

static void savePrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:gElo forKey:PREF_ELO];
    [d setBool:gEnabled forKey:PREF_ENABLED];
    [d setBool:gShowWinPct forKey:PREF_WINPCT];
    [d setInteger:gArrowCount forKey:PREF_ARROWS];
    [d setDouble:gArrowAlpha forKey:PREF_ALPHA];
    [d setDouble:gArrowThick forKey:PREF_THICK];
    [d setBool:gArrowEvalColor forKey:PREF_EVALCLR];
    [d setBool:gTrackQuality forKey:PREF_QUALITY];
    [d setBool:gShowEvalLabels forKey:PREF_EVALLBL];
    [d setBool:gUseMaia forKey:PREF_USEMAIA];
    [d setBool:gAutoPlay forKey:PREF_AUTOPLAY];
    [d setDouble:gAutoPlayDelay forKey:PREF_APDELAY];
    [d setBool:gShowEvalBar forKey:PREF_EVALBAR];
    [d setBool:gAutoPlayJitterEnabled forKey:PREF_APJITEN];
    [d setDouble:gAutoPlayJitterRange forKey:PREF_APJITRNG];
    [d setBool:gAutoPlaySecondBest forKey:PREF_AP2ND];
    [d setInteger:gAutoPlaySecondBestPct forKey:PREF_AP2NDPCT];
    [d synchronize];
}
static void loadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:PREF_ELO]) gElo = [d integerForKey:PREF_ELO];
    if ([d objectForKey:PREF_ENABLED]) gEnabled = [d boolForKey:PREF_ENABLED];
    if ([d objectForKey:PREF_WINPCT]) gShowWinPct = [d boolForKey:PREF_WINPCT];
    if ([d objectForKey:PREF_ARROWS]) gArrowCount = [d integerForKey:PREF_ARROWS];
    if ([d objectForKey:PREF_ALPHA])  gArrowAlpha = [d doubleForKey:PREF_ALPHA];
    if ([d objectForKey:PREF_THICK])  gArrowThick = [d doubleForKey:PREF_THICK];
    if ([d objectForKey:PREF_EVALCLR]) gArrowEvalColor = [d boolForKey:PREF_EVALCLR];
    if ([d objectForKey:PREF_QUALITY]) gTrackQuality = [d boolForKey:PREF_QUALITY];
    if ([d objectForKey:PREF_EVALLBL]) gShowEvalLabels = [d boolForKey:PREF_EVALLBL];
    if ([d objectForKey:PREF_USEMAIA]) gUseMaia = [d boolForKey:PREF_USEMAIA];
    if ([d objectForKey:PREF_AUTOPLAY]) gAutoPlay = [d boolForKey:PREF_AUTOPLAY];
    if ([d objectForKey:PREF_APDELAY]) {
        gAutoPlayDelay = [d doubleForKey:PREF_APDELAY];
        if (gAutoPlayDelay < 0) gAutoPlayDelay = 0;
        if (gAutoPlayDelay > 5.0) gAutoPlayDelay = 5.0;
    }
    if ([d objectForKey:PREF_EVALBAR]) gShowEvalBar = [d boolForKey:PREF_EVALBAR];
    if ([d objectForKey:PREF_APJITEN]) gAutoPlayJitterEnabled = [d boolForKey:PREF_APJITEN];
    if ([d objectForKey:PREF_APJITRNG]) {
        gAutoPlayJitterRange = [d doubleForKey:PREF_APJITRNG];
        if (gAutoPlayJitterRange < 0) gAutoPlayJitterRange = 0;
        if (gAutoPlayJitterRange > 2.0) gAutoPlayJitterRange = 2.0;
    }
    if ([d objectForKey:PREF_AP2ND]) gAutoPlaySecondBest = [d boolForKey:PREF_AP2ND];
    if ([d objectForKey:PREF_AP2NDPCT]) {
        gAutoPlaySecondBestPct = [d integerForKey:PREF_AP2NDPCT];
    }
    if (gAutoPlaySecondBestPct < 0) gAutoPlaySecondBestPct = 0;
    if (gAutoPlaySecondBestPct > 50) gAutoPlaySecondBestPct = 50;
    if (gArrowCount < 1) gArrowCount = 1; if (gArrowCount > 3) gArrowCount = 3;
}

static double evalToWinPct(double pawns, BOOL isMate, int mateIn) {
    if (isMate) return mateIn > 0 ? 100.0 : 0.0;
    double cp = pawns * 100.0;
    double w = 50.0 + 50.0 * (2.0 / (1.0 + exp(-0.00368208 * cp)) - 1.0);
    if (w < 0) w = 0; if (w > 100) w = 100;
    return w;
}

static NSInteger eloToDepth(NSInteger elo) {
    if (elo >= 3000) return 20;  if (elo >= 2600) return 18;
    if (elo >= 2400) return 16;  if (elo >= 2200) return 14;
    if (elo >= 2000) return 13;  if (elo >= 1800) return 12;
    if (elo >= 1600) return 11;  if (elo >= 1400) return 10;
    if (elo >= 1200) return 9;   if (elo >= 1000) return 8;
    if (elo >= 700)  return 6;   if (elo >= 500) return 5;
    return 4;
}

static void showQualityToast(NSString *text, UIColor *color);
static void ensureMaiaLoaded(void);
static NSString *buildPGN(void);
static void updateEvalBar(void);
static void removeEvalBar(void);

static NSString *formatEvalLabel(double evalUs, BOOL isMate, int mateIn) {
    if (isMate) return [NSString stringWithFormat:@"M%d", abs(mateIn)];
    if (gShowWinPct) return [NSString stringWithFormat:@"%.0f%%", evalToWinPct(evalUs, NO, 0)];
    return [NSString stringWithFormat:@"%+.1f", evalUs];
}

static NSString *qName(int i) {
    switch (i) {
        case Q_BRILLIANT: return @"Brilliant";  case Q_GREAT:   return @"Great";
        case Q_BEST:      return @"Best";        case Q_EXCELLENT: return @"Excellent";
        case Q_GOOD:      return @"Good";        case Q_INACC:   return @"Inaccuracy";
        case Q_MISS:      return @"Miss";        case Q_MISTAKE: return @"Mistake";
        default:          return @"Blunder";
    }
}
static NSString *qSymbol(int i) {
    switch (i) {
        case Q_BRILLIANT: return @"!!";  case Q_GREAT:   return @"!";
        case Q_BEST:      return @"★";    case Q_EXCELLENT: return @"✓";
        case Q_GOOD:      return @"•";    case Q_INACC:   return @"?!";
        case Q_MISS:      return @"✗";    case Q_MISTAKE: return @"?";
        default:          return @"??";
    }
}
static UIColor *qColor(int i) {
    switch (i) {
        case Q_BRILLIANT: return [UIColor colorWithRed:0.0 green:0.78 blue:0.78 alpha:1];
        case Q_GREAT:     return [UIColor colorWithRed:0.30 green:0.55 blue:0.95 alpha:1];
        case Q_BEST:      return [UIColor systemGreenColor];
        case Q_EXCELLENT: return [UIColor colorWithRed:0.40 green:0.73 blue:0.42 alpha:1];
        case Q_GOOD:      return [UIColor systemTealColor];
        case Q_INACC:     return [UIColor systemYellowColor];
        case Q_MISS:      return [UIColor colorWithRed:0.95 green:0.45 blue:0.20 alpha:1];
        case Q_MISTAKE:   return [UIColor systemOrangeColor];
        default:          return [UIColor systemRedColor];
    }
}

static double moveAccuracy(double winBefore, double winAfter) {
    double wl = winBefore - winAfter; if (wl < 0) wl = 0;
    double a = 103.1668 * exp(-0.04354 * wl) - 3.1669;
    if (a < 0) a = 0; if (a > 100) a = 100;
    return a;
}

static int fenMaterial(NSString *fen, int color ) {
    NSString *place = [[fen componentsSeparatedByString:@" "] firstObject];
    int sum = 0;
    for (NSUInteger i = 0; i < place.length; i++) {
        unichar ch = [place characterAtIndex:i];
        BOOL isW = (ch >= 'A' && ch <= 'Z'), isB = (ch >= 'a' && ch <= 'z');
        if (!isW && !isB) continue;
        unichar u = isW ? ch : (unichar)(ch - 32);
        int v = (u=='P')?1 : (u=='N'||u=='B')?3 : (u=='R')?5 : (u=='Q')?9 : 0;
        if ((color == 0 && isW) || (color == 1 && isB)) sum += v;
    }
    return sum;
}

// Grade on win-% loss (chess.com-style) instead of raw centipawns — far more
// stable across shallow searches, so genuinely best moves stop showing as
// "Inaccuracy" from ±30cp eval noise.
static int classifyMove(double winLoss, BOOL playedBest, BOOL onlyGood, BOOL sacrificed) {
    if (playedBest && sacrificed) return Q_BRILLIANT;
    if (playedBest && onlyGood)   return Q_GREAT;
    if (winLoss <= 0.5)  return Q_BEST;
    if (winLoss <= 2.0)  return Q_EXCELLENT;
    if (winLoss <= 5.0)  return Q_GOOD;
    if (winLoss <= 10.0) return Q_INACC;
    if (winLoss <= 20.0) return Q_MISTAKE;
    return Q_BLUNDER;
}

static void resetAccuracy(void) {
    gAccSum = 0; gAccCount = 0; gLastMoveQuality = nil;
    for (int i = 0; i < Q_COUNT; i++) gQ[i] = 0;
    gQualHave = NO; gQualHave2nd = NO; gLastQualDone = nil;
}

static void noteUserEval(NSString *fen, double whiteEval, BOOL valid,
                         double secondWhite, BOOL have2nd) {
    gQualFen = [fen copy];
    gQualWhiteEval = whiteEval;
    gQualHave = valid;
    gQual2ndWhite = secondWhite;
    gQualHave2nd = have2nd;
}

static void analyzeUserMove(NSString *oppFen) {
    if (!gTrackQuality || !oppFen.length) return;
    if ([oppFen isEqualToString:gLastQualDone]) return;
    gLastQualDone = [oppFen copy];
    if (!gQualHave) return;
    if ([oppFen isEqualToString:gQualFen]) return;
    if (gMyColor < 0) return;

    double beforeWhite = gQualWhiteEval;
    double secondWhite = gQual2ndWhite;
    BOOL   have2nd     = gQualHave2nd;
    NSString *beforeFen = [gQualFen copy];
    int    userColor   = gMyColor;
    BOOL   stmWhite    = ([oppFen rangeOfString:@" w "].location != NSNotFound);
    NSInteger depth    = MAX(14, eloToDepth(gElo)); // stable evals matter more than speed here

    EngineGo([oppFen UTF8String], (int)depth, (int)gElo, 1,
             ^(const EngineLine *lines, int count) {
        BOOL hs   = count > 0 && lines[0].hasScore;
        BOOL mate = count > 0 && lines[0].isMate;
        int  sc   = count > 0 ? lines[0].score : 0;
        if (!hs || mate) return;
        double afterWhite = (sc / 100.0) * (stmWhite ? 1 : -1);
        dispatch_async(dispatch_get_main_queue(), ^{
            double beforeUs = (userColor == 1) ? -beforeWhite : beforeWhite;
            double afterUs  = (userColor == 1) ? -afterWhite  : afterWhite;
            double secondUs = (userColor == 1) ? -secondWhite : secondWhite;

            double winBefore = evalToWinPct(beforeUs, NO, 0);
            double winAfter  = evalToWinPct(afterUs, NO, 0);
            double winLoss   = winBefore - winAfter;
            if (winLoss < 0) winLoss = 0;

            BOOL playedBest = winLoss <= 0.5;
            BOOL onlyGood   = have2nd && (beforeUs - secondUs) >= 1.5;

            int dBefore = fenMaterial(beforeFen, userColor) - fenMaterial(beforeFen, 1 - userColor);
            int dAfter  = fenMaterial(oppFen,    userColor) - fenMaterial(oppFen,    1 - userColor);
            BOOL sacrificed = (dAfter <= -2) && (dAfter < dBefore);

            int cat = classifyMove(winLoss, playedBest, onlyGood, sacrificed);
            gQ[cat]++;
            double acc = moveAccuracy(winBefore, winAfter);
            gAccSum += acc; gAccCount++;
            gLastMoveQuality = [NSString stringWithFormat:@"%@ (-%.1f%%)", qName(cat), winLoss];
            showQualityToast([NSString stringWithFormat:@"%@ %@", qSymbol(cat), qName(cat)], qColor(cat));
        });
    });
}

static char gBoard[64];
static int  gSide;
static int  gCastle;
static int  gEp;
static int  gHalf;
static int  gFull;

static void parseFEN(NSString *fen) {
    memset(gBoard, ' ', 64);
    gSide = 0; gCastle = 0; gEp = -1; gHalf = 0; gFull = 1;
    if (!fen.length) fen = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    NSArray *parts = [fen componentsSeparatedByString:@" "];
    NSString *placement = parts[0];
    int sq = 56;
    for (NSUInteger i = 0; i < placement.length; i++) {
        unichar c = [placement characterAtIndex:i];
        if (c == '/') { sq -= 16; }
        else if (c >= '1' && c <= '8') { sq += (c - '0'); }
        else { if (sq >= 0 && sq < 64) gBoard[sq] = (char)c; sq++; }
    }
    if (parts.count > 1) gSide = [[parts[1] lowercaseString] isEqualToString:@"b"] ? 1 : 0;
    if (parts.count > 2) {
        NSString *cas = parts[2];
        if ([cas containsString:@"K"]) gCastle |= 1;
        if ([cas containsString:@"Q"]) gCastle |= 2;
        if ([cas containsString:@"k"]) gCastle |= 4;
        if ([cas containsString:@"q"]) gCastle |= 8;
    }
    if (parts.count > 3 && ![parts[3] isEqualToString:@"-"]) {
        NSString *ep = parts[3];
        if (ep.length >= 2) {
            int file = [ep characterAtIndex:0] - 'a';
            int rank = [ep characterAtIndex:1] - '1';
            if (file >= 0 && file < 8 && rank >= 0 && rank < 8) gEp = rank * 8 + file;
        }
    }
    if (parts.count > 4) gHalf = [parts[4] intValue];
    if (parts.count > 5) gFull = [parts[5] intValue];
}

static void applyMove(int from, int to, char promo) {
    if (from < 0 || from > 63 || to < 0 || to > 63) return;
    char piece = gBoard[from];
    char captured = gBoard[to];
    gBoard[from] = ' ';
    if ((piece == 'P' || piece == 'p') && to == gEp) {
        int capSq = (piece == 'P') ? to - 8 : to + 8;
        if (capSq >= 0 && capSq < 64) gBoard[capSq] = ' ';
    }
    if (piece == 'K' && from == 4) {
        if (to == 6) { gBoard[5] = gBoard[7]; gBoard[7] = ' '; }
        else if (to == 2) { gBoard[3] = gBoard[0]; gBoard[0] = ' '; }
    }
    if (piece == 'k' && from == 60) {
        if (to == 62) { gBoard[61] = gBoard[63]; gBoard[63] = ' '; }
        else if (to == 58) { gBoard[59] = gBoard[56]; gBoard[56] = ' '; }
    }
    if (promo) gBoard[to] = (gSide == 0) ? (char)toupper(promo) : (char)tolower(promo);
    else gBoard[to] = piece;
    gEp = -1;
    if (piece == 'P' && (to - from) == 16) gEp = from + 8;
    if (piece == 'p' && (from - to) == 16) gEp = from - 8;
    if (piece == 'K') gCastle &= ~3;
    if (piece == 'k') gCastle &= ~12;
    if (from == 0 || to == 0) gCastle &= ~2;
    if (from == 7 || to == 7) gCastle &= ~1;
    if (from == 56 || to == 56) gCastle &= ~8;
    if (from == 63 || to == 63) gCastle &= ~4;
    if (piece == 'P' || piece == 'p' || captured != ' ') gHalf = 0; else gHalf++;
    if (gSide == 1) gFull++;
    gSide = 1 - gSide;
}

static NSString *generateFEN(void) {
    NSMutableString *fen = [NSMutableString string];
    for (int rank = 7; rank >= 0; rank--) {
        int empty = 0;
        for (int file = 0; file < 8; file++) {
            char p = gBoard[rank * 8 + file];
            if (p == ' ') { empty++; }
            else {
                if (empty) { [fen appendFormat:@"%d", empty]; empty = 0; }
                [fen appendFormat:@"%c", p];
            }
        }
        if (empty) [fen appendFormat:@"%d", empty];
        if (rank > 0) [fen appendString:@"/"];
    }
    [fen appendFormat:@" %c ", gSide == 0 ? 'w' : 'b'];
    NSMutableString *cas = [NSMutableString string];
    if (gCastle & 1) [cas appendString:@"K"];
    if (gCastle & 2) [cas appendString:@"Q"];
    if (gCastle & 4) [cas appendString:@"k"];
    if (gCastle & 8) [cas appendString:@"q"];
    [fen appendString:cas.length ? cas : @"-"];
    if (gEp >= 0) [fen appendFormat:@" %c%c", 'a'+(gEp%8), '1'+(gEp/8)];
    else [fen appendString:@" -"];
    [fen appendFormat:@" %d %d", gHalf, gFull];
    return fen;
}

static NSString *TCN_TABLE = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?{~}(^)[_]@#$,./`-*+=";

static int tcnIndex(unichar c) {
    NSUInteger idx = [TCN_TABLE rangeOfString:[NSString stringWithCharacters:&c length:1]].location;
    return (idx == NSNotFound) ? -1 : (int)idx;
}

static NSString *decodeTCNToFEN(NSString *initialFEN, NSString *encoded) {
    parseFEN(initialFEN);
    gPgnStartFen = [initialFEN copy];
    if (!gUciSeq) gUciSeq = [NSMutableString string];
    [gUciSeq setString:@""];
    if (!encoded.length) return generateFEN();
    for (NSUInteger i = 0; i + 1 < encoded.length; i += 2) {
        int fromIdx = tcnIndex([encoded characterAtIndex:i]);
        int toIdx   = tcnIndex([encoded characterAtIndex:i + 1]);
        if (fromIdx < 0 || fromIdx > 63 || toIdx < 0) continue;
        int from = fromIdx, to;
        char promo = 0;
        if (toIdx <= 63) {
            to = toIdx;
        } else {
            int offset = toIdx - 64;
            int pieceIdx = offset / 3;
            int dir = offset % 3;
            static const char promoChars[] = "qnrb";
            if (pieceIdx < 4) promo = promoChars[pieceIdx];
            int fromFile = from % 8;
            int toFile = fromFile + dir - 1;
            to = (from >= 48) ? (56 + toFile) : (0 + toFile);
        }
        applyMove(from, to, promo);
        char u[6] = { (char)('a' + from % 8), (char)('1' + from / 8),
                      (char)('a' + to % 8),   (char)('1' + to / 8),
                      (char)(promo ? tolower((unsigned char)promo) : 0), 0 };
        [gUciSeq appendFormat:@"%s ", u];
    }
    return generateFEN();
}

static NSMutableArray<CALayer *> *gArrowLayers = nil;
static __weak UIView *gBoardView = nil;
static __weak UIView *gBotBoard  = nil;
static __weak UIView *gPuzzleBoard = nil;
static __weak UIView *gDrawBoard = nil;
static __weak UIView *gOnlineDrawBoard = nil;
static NSDate *gBotSeen    = nil;
static NSDate *gOnlineSeen = nil;
static NSArray *gCurrentArrows = nil;
static BOOL    gArrowFlipped = NO;

static CGPoint squareToPoint(int sq, CGRect bounds, BOOL flipped) {
    int file = sq % 8;
    int rank = sq / 8;
    CGFloat sqW = bounds.size.width / 8.0;
    CGFloat sqH = bounds.size.height / 8.0;
    CGFloat x, y;
    if (flipped) {
        x = (7 - file) * sqW + sqW / 2.0;
        y = rank * sqH + sqH / 2.0;
    } else {
        x = file * sqW + sqW / 2.0;
        y = (7 - rank) * sqH + sqH / 2.0;
    }
    return CGPointMake(x, y);
}

static BOOL parseMoveUCI(NSString *move, int *fromSq, int *toSq) {
    if (move.length < 4) return NO;
    int ff = [move characterAtIndex:0] - 'a';
    int fr = [move characterAtIndex:1] - '1';
    int tf = [move characterAtIndex:2] - 'a';
    int tr = [move characterAtIndex:3] - '1';
    if (ff < 0 || ff > 7 || fr < 0 || fr > 7 || tf < 0 || tf > 7 || tr < 0 || tr > 7) return NO;
    *fromSq = fr * 8 + ff;
    *toSq   = tr * 8 + tf;
    return YES;
}

static UIBezierPath *arrowPath(CGPoint from, CGPoint to, CGFloat headLen, CGFloat headW, CGFloat shaftW) {
    CGFloat dx = to.x - from.x, dy = to.y - from.y;
    CGFloat len = sqrtf(dx * dx + dy * dy);
    if (len < 1) return nil;

    CGFloat ux = dx / len, uy = dy / len;
    CGFloat px = -uy,      py = ux;

    CGPoint shaftL1 = { from.x + px * shaftW / 2, from.y + py * shaftW / 2 };
    CGPoint shaftR1 = { from.x - px * shaftW / 2, from.y - py * shaftW / 2 };
    CGPoint neckL   = { to.x - ux * headLen + px * shaftW / 2, to.y - uy * headLen + py * shaftW / 2 };
    CGPoint neckR   = { to.x - ux * headLen - px * shaftW / 2, to.y - uy * headLen - py * shaftW / 2 };
    CGPoint wingL   = { to.x - ux * headLen + px * headW / 2,  to.y - uy * headLen + py * headW / 2 };
    CGPoint wingR   = { to.x - ux * headLen - px * headW / 2,  to.y - uy * headLen - py * headW / 2 };

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:shaftL1];
    [path addLineToPoint:neckL];
    [path addLineToPoint:wingL];
    [path addLineToPoint:to];
    [path addLineToPoint:wingR];
    [path addLineToPoint:neckR];
    [path addLineToPoint:shaftR1];
    [path closePath];
    return path;
}

static void clearArrow(void) {
    if (gArrowLayers) {
        for (CALayer *l in gArrowLayers) [l removeFromSuperlayer];
        [gArrowLayers removeAllObjects];
    }
    gCurrentArrows = nil;
}

static CAShapeLayer *buildArrowLayer(NSString *moveUCI, CGRect bounds, BOOL flipped,
                                     double evalForUs, int rank) {
    int fromSq = 0, toSq = 0;
    if (!parseMoveUCI(moveUCI, &fromSq, &toSq)) return nil;
    if (bounds.size.width < 8) return nil;

    CGFloat sqSize = bounds.size.width / 8.0;
    CGPoint fromPt = squareToPoint(fromSq, bounds, flipped);
    CGPoint toPt   = squareToPoint(toSq,   bounds, flipped);

    CGFloat t = gArrowThick;
    UIBezierPath *path = arrowPath(fromPt, toPt, sqSize * 0.45, sqSize * 0.65 * t, sqSize * 0.25 * t);
    if (!path) return nil;

    CGFloat a = gArrowAlpha;
    UIColor *fillColor, *strokeColor;
    if (rank > 0) {

        CGFloat sa = a * 0.55;
        fillColor   = [UIColor colorWithRed:0.55 green:0.55 blue:0.6 alpha:sa];
        strokeColor = [UIColor colorWithRed:0.35 green:0.35 blue:0.4 alpha:MIN(1.0, sa + 0.2)];
    } else if (!gArrowEvalColor) {
        fillColor   = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:a];
        strokeColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.1 alpha:MIN(1.0, a + 0.2)];
    } else if (evalForUs > 1.0) {
        fillColor   = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:a];
        strokeColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.1 alpha:MIN(1.0, a + 0.2)];
    } else if (evalForUs < -1.0) {
        fillColor   = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:a];
        strokeColor = [UIColor colorWithRed:0.6 green:0.1 blue:0.1 alpha:MIN(1.0, a + 0.2)];
    } else {
        fillColor   = [UIColor colorWithRed:0.95 green:0.75 blue:0.1 alpha:a];
        strokeColor = [UIColor colorWithRed:0.7  green:0.55 blue:0.0 alpha:MIN(1.0, a + 0.2)];
    }

    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.path = path.CGPath;
    layer.fillColor = fillColor.CGColor;
    layer.strokeColor = strokeColor.CGColor;
    layer.lineWidth = 1.5;
    layer.zPosition = 9999 - rank;
    return layer;
}

static void drawArrowsCore(UIView *board, BOOL flipped) {
    if (!board || !board.window || !gCurrentArrows.count) return;
    CGRect bounds = board.bounds;
    CGFloat sqSize = bounds.size.width / 8.0;
    if (!gArrowLayers) gArrowLayers = [NSMutableArray array];
    for (CALayer *l in gArrowLayers) [l removeFromSuperlayer];
    [gArrowLayers removeAllObjects];

    for (NSDictionary *a in gCurrentArrows) {
        CAShapeLayer *layer = buildArrowLayer(a[@"move"], bounds, flipped,
                                              [a[@"eval"] doubleValue], [a[@"rank"] intValue]);
        if (layer) { [board.layer addSublayer:layer]; [gArrowLayers addObject:layer]; }

        NSString *label = a[@"label"];
        int fromSq = 0, toSq = 0;
        if (gShowEvalLabels && label.length && parseMoveUCI(a[@"move"], &fromSq, &toSq)) {
            CGPoint toPt = squareToPoint(toSq, bounds, flipped);
            CATextLayer *tl = [CATextLayer layer];
            tl.string = label;
            tl.fontSize = MAX(8.0, sqSize * 0.30);
            tl.alignmentMode = kCAAlignmentCenter;
            tl.foregroundColor = [UIColor whiteColor].CGColor;
            tl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6].CGColor;
            tl.cornerRadius = 3; tl.masksToBounds = YES;
            tl.contentsScale = [UIScreen mainScreen].scale;
            CGFloat lw = sqSize * 0.7, lh = sqSize * 0.36;
            tl.frame = CGRectMake(toPt.x - lw / 2, toPt.y - lh / 2, lw, lh);
            tl.zPosition = 10001;
            [board.layer addSublayer:tl]; [gArrowLayers addObject:tl];
        }
    }
}

static void reassertArrow(UIView *board);
static BOOL isBoardOnScreen(UIView *v);

static void drawArrowsOnBoard(NSArray *arrows, UIView *board, BOOL flipped) {
    dispatch_async(dispatch_get_main_queue(), ^{
        clearArrow();
        gCurrentArrows = [arrows copy];
        gArrowFlipped = flipped;
        drawArrowsCore(board, flipped);
        if (gArrowLayers.count)
            dbg([NSString stringWithFormat:@"arrows: %lu", (unsigned long)gArrowLayers.count]);

        for (double delay = 0.4; delay <= 2.0; delay += 0.5) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ reassertArrow(board); });
        }
    });
}

static void reassertArrow(UIView *board) {
    if (!gCurrentArrows.count || !board || !board.window) return;
    CALayer *first = gArrowLayers.firstObject;
    if (first && first.superlayer == board.layer) return;
    drawArrowsCore(board, gArrowFlipped);
}

static void showSettingsMenu(void);

@interface CHAssistBtnHandler : NSObject
+ (void)floatBtnTapped;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp;
@end

@implementation CHAssistBtnHandler
+ (void)floatBtnTapped {
    if (gSkipNextTap) { gSkipNextTap = NO; return; }
    showSettingsMenu();
}
+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    UIView *container = btn.superview;
    CGPoint translation = [pan translationInView:container];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:container];
}
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    gSkipNextTap = YES;
    gEnabled = !gEnabled;
    savePrefs();
    if (!gEnabled) clearArrow();
    dbg([NSString stringWithFormat:@"quick toggle: %@", gEnabled ? @"ON" : @"OFF"]);
    showQualityToast(gEnabled ? @"▶ Assistant On" : @"⏸ Assistant Paused",
                     gEnabled ? CH_ACCENT : [UIColor systemRedColor]);
}
@end

static UIWindow *gBtnWin = nil;
static UIButton *gFloatBtn = nil;

static void setupFloatingButton(void) {
    if (gBtnWin) return;

    UIWindowScene *activeScene = nil;
    if (@available(iOS 13, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)sc;
                break;
            }
        }
    }

    if (@available(iOS 13, *)) {
        if (activeScene) gBtnWin = [[UIWindow alloc] initWithWindowScene:activeScene];
    }
    if (!gBtnWin) gBtnWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    gBtnWin.windowLevel = UIWindowLevelAlert + 2;
    gBtnWin.backgroundColor = [UIColor clearColor];
    gBtnWin.userInteractionEnabled = YES;
    gBtnWin.rootViewController = [[UIViewController alloc] init];
    gBtnWin.rootViewController.view.backgroundColor = [UIColor clearColor];

    gBtnWin.rootViewController.view.userInteractionEnabled = YES;

    CGFloat btnSize = 40;
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    CGFloat x = screenW - btnSize - 8;
    CGFloat y = screenH * 0.45;

    gFloatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    gFloatBtn.frame = CGRectMake(x, y, btnSize, btnSize);
    gFloatBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.85];
    gFloatBtn.layer.cornerRadius = 8;
    gFloatBtn.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:1].CGColor;
    gFloatBtn.layer.borderWidth = 1;
    [gFloatBtn setTitle:@"♟" forState:UIControlStateNormal];
    gFloatBtn.titleLabel.font = [UIFont systemFontOfSize:20];
    [gFloatBtn addTarget:[CHAssistBtnHandler class] action:@selector(floatBtnTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[CHAssistBtnHandler class] action:@selector(handlePan:)];
    [gFloatBtn addGestureRecognizer:pan];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[CHAssistBtnHandler class] action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.45;
    [gFloatBtn addGestureRecognizer:lp];

    [gBtnWin.rootViewController.view addSubview:gFloatBtn];
    gBtnWin.hidden = NO;
    [gBtnWin makeKeyAndVisible];

    [[UIApplication sharedApplication].delegate.window makeKeyWindow];
}

%hook UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self == gBtnWin) {

        CGPoint btnPoint = [gFloatBtn convertPoint:point fromView:self.rootViewController.view];
        if ([gFloatBtn pointInside:btnPoint withEvent:event]) {
            return gFloatBtn;
        }
        return nil;
    }
    return %orig;
}
%end

static UIWindow *gMenuWin = nil;

static UIWindow *menuWin(void) {
    if (gMenuWin) return gMenuWin;
    if (@available(iOS 13, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                gMenuWin = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)sc];
                break;
            }
        }
    }
    if (!gMenuWin) gMenuWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gMenuWin.windowLevel = UIWindowLevelAlert + 3;
    gMenuWin.rootViewController = [[UIViewController alloc] init];
    gMenuWin.backgroundColor = [UIColor clearColor];
    gMenuWin.hidden = YES;
    return gMenuWin;
}

static void hideMenu(void) {
    gMenuWin.hidden = YES;
    [[UIApplication sharedApplication].delegate.window makeKeyWindow];
}

static void showAC(UIAlertController *ac) {
    UIWindow *w = menuWin();
    w.hidden = NO;
    [w makeKeyAndVisible];
    UIViewController *r = w.rootViewController;
    if (r.presentedViewController)
        [r dismissViewControllerAnimated:NO completion:^{ [r presentViewController:ac animated:YES completion:nil]; }];
    else [r presentViewController:ac animated:YES completion:nil];
}

static UIView *findBoardArea(UIView *view, int depth);

static void showDebugLog(void) {
    NSString *logStr = gLog.count ? [gLog componentsJoinedByString:@"\n"] : @"No entries.";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Debug Log"
        message:logStr
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"📋 Copy Logs" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            [UIPasteboard generalPasteboard].string = logStr;
            hideMenu();
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *_) { [gLog removeAllObjects]; hideMenu(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { hideMenu(); }]];
    showAC(ac);
}

static void showCredits(void) {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Chess Assistant"
        message:@"Made by @epicccccc\n\nYouTube: @epicccccc\nDiscord: itzzace.\n\nSF18 + Auto Play by Yousseif\nGitHub: usif-x"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) { hideMenu(); }]];
    showAC(ac);
}

#if 0
static void reopenSettings(void) {
    hideMenu();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ showSettingsMenu(); });
}
#endif

static void redrawArrows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *b = gDrawBoard ?: gBoardView;
        if (b && b.window && gCurrentArrows.count) drawArrowsCore(b, gArrowFlipped);
    });
}

#if 0
static void showEloMenu(void) {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Set ELO"
        message:@"Higher = stronger but riskier. ⚠️ = above ~1500 (ban risk)."
        preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *levels = @[@400, @600, @800, @1000, @1200, @1400, @1600, @1800,
                        @2000, @2200, @2400, @2800, @3200, @3500];
    NSArray *names  = @[@"400 Novice", @"600 Beginner", @"800 Casual", @"1000 Improving",
                        @"1200 Intermediate", @"1400 Club", @"1600 Strong Club", @"1800 Expert",
                        @"2000 Candidate Master", @"2200 Master", @"2400 IM/GM",
                        @"2800 Super-GM", @"3200 Engine", @"3500 Max"];
    for (NSUInteger i = 0; i < levels.count; i++) {
        NSInteger lvl = [levels[i] integerValue];
        [ac addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"%@%@%@", names[i],
                             lvl > 1500 ? @" ⚠️" : @"", lvl == gElo ? @" ✓" : @""]
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *_) {
                gElo = lvl;
                savePrefs();
                dbg([NSString stringWithFormat:@"ELO set to %ld", (long)lvl]);
                if (lvl > 1500) {
                    UIAlertController *w = [UIAlertController
                        alertControllerWithTitle:@"⚠️ Ban Risk"
                        message:@"Playing above ~1500 strength is much easier for Chess.com's "
                                 "fair-play system to detect and greatly increases your risk of "
                                 "an account ban. Lower ELO is safer."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [w addAction:[UIAlertAction actionWithTitle:@"I understand"
                        style:UIAlertActionStyleDestructive
                        handler:^(UIAlertAction *_2) { hideMenu(); }]];
                    showAC(w);
                } else {
                    hideMenu();
                }
            }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { hideMenu(); }]];

    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        UIView *v = menuWin().rootViewController.view;
        pop.sourceView = v;
        pop.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds), 0, 0);
        pop.permittedArrowDirections = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ showAC(ac); });
}

static void showArrowStyleMenu(void) {
    NSString *opacityTxt = [NSString stringWithFormat:@"Opacity: %.0f%%", gArrowAlpha * 100];
    NSString *thickTxt   = gArrowThick < 0.85 ? @"Thickness: Thin" :
                           (gArrowThick > 1.2 ? @"Thickness: Thick" : @"Thickness: Normal");
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Arrow Style" message:nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"Color: %@", gArrowEvalColor ? @"By Eval" : @"Green"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            gArrowEvalColor = !gArrowEvalColor; savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:opacityTxt
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            CGFloat steps[] = {0.4, 0.55, 0.7, 0.85, 1.0};
            int idx = 0; for (int i = 0; i < 5; i++) if (gArrowAlpha >= steps[i] - 0.01) idx = i;
            gArrowAlpha = steps[(idx + 1) % 5]; savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:thickTxt
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            gArrowThick = gArrowThick < 0.85 ? 1.0 : (gArrowThick > 1.2 ? 0.7 : 1.4);
            savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"Eval Labels: %@", gShowEvalLabels ? @"On" : @"Off"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            gShowEvalLabels = !gShowEvalLabels; savePrefs(); redrawArrows();
            hideMenu(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"‹ Back" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { reopenSettings(); }]];

    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        UIView *v = menuWin().rootViewController.view;
        pop.sourceView = v;
        pop.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds), 0, 0);
        pop.permittedArrowDirections = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ showAC(ac); });
}

static void showSettingsMenu(void) {
    NSString *accLine = @"";
    if (gTrackQuality && gAccCount > 0) {
        accLine = [NSString stringWithFormat:@"\nAccuracy: %.0f%% (%d moves)\n✓%d  ?!%d  ?%d  ??%d%@",
                   gAccSum / gAccCount, gAccCount, gQGood, gQInacc, gQMist, gQBlund,
                   gLastMoveQuality.length ? [@"\nLast: " stringByAppendingString:gLastMoveQuality] : @""];
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Chess Assistant"
        message:[NSString stringWithFormat:@"ELO: %ld | %@ | Depth: %ld\nPlaying: %@%@\n\nby @epicccccc",
                 (long)gElo, gEnabled ? @"ON" : @"OFF", (long)eloToDepth(gElo),
                 gMyColor == 0 ? @"White" : (gMyColor == 1 ? @"Black" : @"Unknown"), accLine]
        preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"🎚 Set ELO (%ld)%@", (long)gElo,
                         gElo > 1500 ? @" ⚠️" : @""]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showEloMenu(); });
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"📊 Eval: %@", gShowWinPct ? @"Win %" : @"Centipawn"]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            gShowWinPct = !gShowWinPct; savePrefs();
            dbg([NSString stringWithFormat:@"Eval display: %@", gShowWinPct ? @"win%" : @"cp"]);
            reopenSettings();
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"➹ Arrows: %ld", (long)gArrowCount]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            gArrowCount = (gArrowCount % 3) + 1;
            savePrefs();
            gLastFen = nil;
            dbg([NSString stringWithFormat:@"Arrows: %ld", (long)gArrowCount]);
            reopenSettings();
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"🎨 Arrow Style"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showArrowStyleMenu(); });
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:@"🎯 Move Analysis: %@", gTrackQuality ? @"On" : @"Off"]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            gTrackQuality = !gTrackQuality; savePrefs();
            if (!gTrackQuality) resetAccuracy();
            dbg([NSString stringWithFormat:@"Move analysis: %@", gTrackQuality ? @"on" : @"off"]);
            reopenSettings();
        }]];

    [ac addAction:[UIAlertAction
        actionWithTitle:gEnabled ? @"⏸ Disable" : @"▶ Enable"
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *_) {
            gEnabled = !gEnabled;
            savePrefs();
            if (!gEnabled) clearArrow();
            dbg([NSString stringWithFormat:@"Toggled: %@", gEnabled ? @"ON" : @"OFF"]);
            hideMenu();
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"📋 Debug Log"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showDebugLog(); });
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Credits"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            hideMenu();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showCredits(); });
        }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Close"
        style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_) { hideMenu(); }]];

    UIPopoverPresentationController *pop = ac.popoverPresentationController;
    if (pop) {
        UIView *v = menuWin().rootViewController.view;
        pop.sourceView = v;
        pop.sourceRect = CGRectMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds), 0, 0);
        pop.permittedArrowDirections = 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ showAC(ac); });
}
#endif


@interface CHPad : UILabel @end
@implementation CHPad
- (void)drawTextInRect:(CGRect)r {
    [super drawTextInRect:UIEdgeInsetsInsetRect(r, UIEdgeInsetsMake(3, 9, 3, 9))];
}
- (CGSize)intrinsicContentSize {
    CGSize s = [super intrinsicContentSize];
    return CGSizeMake(s.width + 18, s.height + 6);
}
@end

static const NSInteger kEloLevels[] = {400,600,800,1000,1200,1400,1600,1800,2000,2200,2400,2800,3200,3500};
static const int kEloCount = 14;
static NSString *ecoName(void) {
    if (!gUciSeq || !gUciSeq.length) return nil;
    static NSDictionary<NSString *, NSString *> *sTable = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTable = @{
            @"e2e4 e7e5":                                   @"Open Game",
            @"e2e4 e7e5 g1f3 b8c6 f1b5":                    @"Ruy Lopez",
            @"e2e4 e7e5 g1f3 b8c6 f1b5 a7a6":               @"Ruy Lopez, Closed",
            @"e2e4 e7e5 g1f3 b8c6 f1b5 g8f6":               @"Ruy Lopez, Berlin",
            @"e2e4 e7e5 g1f3 b8c6 f1c4":                    @"Italian Game",
            @"e2e4 e7e5 g1f3 b8c6 d2d4":                    @"Scotch Game",
            @"e2e4 e7e5 g1f3 g8f6":                         @"Petrov Defense",
            @"e2e4 e7e5 g1f3 f8c5":                         @"Giuoco Piano",
            @"e2e4 e7e5 b1c3":                              @"Vienna Game",
            @"e2e4 e7e5 f2f4":                              @"King's Gambit",
            @"e2e4 c7c5":                                   @"Sicilian Defense",
            @"e2e4 c7c5 c2c3":                              @"Sicilian, Alapin",
            @"e2e4 c7c5 b1c3":                              @"Sicilian, Closed",
            @"e2e4 c7c5 g2g3":                              @"Sicilian, Fianchetto",
            @"e2e4 c7c5 g1f3 b8c6":                         @"Sicilian, Old",
            @"e2e4 c7c5 g1f3 d7d6":                         @"Sicilian, Open",
            @"e2e4 c7c5 g1f3 e7e6":                         @"Sicilian, French",
            @"e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 g1d4 g8f6 b1c3 a7a6": @"Sicilian, Najdorf",
            @"e2e4 e7e6":                                   @"French Defense",
            @"e2e4 c7c6":                                   @"Caro-Kann Defense",
            @"e2e4 d7d6":                                   @"Pirc Defense",
            @"e2e4 d7d5":                                   @"Scandinavian Defense",
            @"e2e4 g8f6":                                   @"Alekhine Defense",
            @"d2d4 d7d5":                                   @"Closed Game",
            @"d2d4 d7d5 c2c4":                              @"Queen's Gambit",
            @"d2d4 d7d5 c2c4 e7e6":                         @"Queen's Gambit Declined",
            @"d2d4 d7d5 c2c4 c7c6":                         @"Slav Defense",
            @"d2d4 d7d5 c2c4 d5c4":                         @"Queen's Gambit Accepted",
            @"d2d4 g8f6":                                   @"Indian Defense",
            @"d2d4 g8f6 c2c4 e7e6":                         @"Indian, Queen's",
            @"d2d4 g8f6 c2c4 g7g6":                         @"King's Indian / Grünfeld",
            @"d2d4 g8f6 g1f3 g7g6":                         @"King's Indian Attack",
            @"d2d4 f7f5":                                   @"Dutch Defense",
            @"c2c4":                                        @"English Opening",
            @"c2c4 e7e5":                                   @"English, Reversed Sicilian",
            @"c2c4 g8f6":                                   @"English, Anglo-Indian",
            @"g1f3 d7d5 c2c4":                              @"Réti Opening",
            @"f2f4":                                        @"Bird's Opening",
        };
    });
    NSString *seq = [gUciSeq stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    __block NSString *best = nil;
    __block NSUInteger bestLen = 0;
    [sTable enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        if ([seq hasPrefix:k] && k.length > bestLen) { best = v; bestLen = k.length; }
    }];
    return best;
}

static NSString *eloTierName(NSInteger e) {    if (e < 600)  return @"Novice";        if (e < 800)  return @"Beginner";
    if (e < 1000) return @"Casual";        if (e < 1200) return @"Improving";
    if (e < 1400) return @"Intermediate";  if (e < 1600) return @"Club";
    if (e < 1800) return @"Strong Club";   if (e < 2000) return @"Expert";
    if (e < 2200) return @"Cand. Master";  if (e < 2400) return @"Master";
    if (e < 2800) return @"IM / GM";       if (e < 3200) return @"Super-GM";
    if (e < 3500) return @"Engine";        return @"Maximum";
}
static const NSInteger kMaiaLevels[] = {600,700,800,900,1000,1100,1200,1300,1400,1500,1600,1700,
                                        1800,1900,2000,2100,2200,2300,2400,2500,2600,2700,2800,2900};
static const int kMaiaLevelCount = 24;

static const NSInteger *activeEloLevels(int *outCount) {
    if (gUseMaia) { *outCount = kMaiaLevelCount; return kMaiaLevels; }
    *outCount = kEloCount; return kEloLevels;
}
static int activeEloNearestIndex(NSInteger e) {
    int c = 0; const NSInteger *l = activeEloLevels(&c);
    int best = 0; long bd = LONG_MAX;
    for (int i = 0; i < c; i++) { long d = labs((long)(l[i] - e)); if (d < bd) { bd = d; best = i; } }
    return best;
}
static NSInteger activeEloForIndex(int i) {
    int c = 0; const NSInteger *l = activeEloLevels(&c);
    if (i < 0) i = 0; if (i >= c) i = c - 1;
    return l[i];
}
static void clampGeloToActiveRange(void) {
    int c = 0; const NSInteger *l = activeEloLevels(&c);
    if (gElo < l[0]) gElo = l[0];
    if (gElo > l[c-1]) gElo = l[c-1];
}

@interface CHSettingsPanel : UIView {
    UIView      *_card;
    UIStackView *_stack;
    UIScrollView *_scroll;
    UILabel     *_eloValue;
    UILabel     *_eloTier;
    UILabel     *_apDelayValue;
    UILabel     *_apJitterValue;
    UILabel     *_apSecondPctValue;
    UILabel     *_opValue;
}
@end

@implementation CHSettingsPanel

+ (void)show {
    UIWindow *w = menuWin();
    w.hidden = NO; [w makeKeyAndVisible];
    UIView *root = w.rootViewController.view;
    for (UIView *v in [root.subviews copy])
        if ([v isKindOfClass:[CHSettingsPanel class]]) [v removeFromSuperview];
    CHSettingsPanel *p = [[CHSettingsPanel alloc] initWithFrame:root.bounds];
    p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:p];
    [p build];
    [p animateIn];
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor clearColor];
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTap:)];
        t.cancelsTouchesInView = NO;
        [self addGestureRecognizer:t];
    }
    return self;
}

- (void)bgTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    if (_card && CGRectContainsPoint(_card.frame, p)) return;
    [self animateOut];
}

- (UILabel *)lbl:(NSString *)t size:(CGFloat)s weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] init];
    l.text = t; l.textColor = c; l.font = [UIFont systemFontOfSize:s weight:w];
    l.numberOfLines = 1;
    NSLayoutConstraint *h = [l.heightAnchor constraintGreaterThanOrEqualToConstant:ceil(s * 1.35)];
    h.priority = 999; h.active = YES;
    return l;
}

- (UIView *)sep {
    UIView *s = [[UIView alloc] init];
    s.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [s.heightAnchor constraintEqualToConstant:1].active = YES;
    return s;
}

- (UIView *)sliderRow:(UISlider *)s {
    s.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *h = [s.heightAnchor constraintEqualToConstant:32];
    h.priority = 999; h.active = YES;
    UIView *box = [[UIView alloc] init];
    [box addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:box.topAnchor constant:2],
        [s.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-2],
        [s.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
        [s.trailingAnchor constraintEqualToAnchor:box.trailingAnchor]]];
    return box;
}

- (UILabel *)sectionLabel:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t.uppercaseString;
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:l.text attributes:@{
        NSFontAttributeName: l.font,
        NSForegroundColorAttributeName: l.textColor,
        NSKernAttributeName: @1.2
    }];
    l.attributedText = attr;
    NSLayoutConstraint *h = [l.heightAnchor constraintGreaterThanOrEqualToConstant:16];
    h.priority = 999; h.active = YES;
    return l;
}

- (UIView *)group:(UIView *)inner {
    UIView *box = [[UIView alloc] init];
    box.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    box.layer.cornerRadius = 14;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:box.topAnchor constant:12],
        [inner.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-12],
        [inner.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],
        [inner.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14]]];
    return box;
}

- (UIView *)rowTitle:(NSString *)t control:(UIView *)ctrl {
    UILabel *l = [self lbl:t size:15 weight:UIFontWeightMedium color:UIColor.whiteColor];
    NSMutableArray *arr = [NSMutableArray array];
    if (ctrl) {
        ctrl.translatesAutoresizingMaskIntoConstraints = NO;
        [arr addObject:l];
        [arr addObject:ctrl];
    } else {
        [arr addObject:l];
    }
    UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:arr];
    h.axis = UILayoutConstraintAxisHorizontal; h.alignment = UIStackViewAlignmentCenter;
    h.distribution = UIStackViewDistributionFill;
    [l setContentHuggingPriority:250 forAxis:UILayoutConstraintAxisHorizontal];
    if (ctrl) {
        [ctrl setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        [ctrl setContentCompressionResistancePriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        if ([ctrl isKindOfClass:[UISlider class]]) [ctrl.widthAnchor constraintEqualToConstant:150].active = YES;
    }
    return h;
}

- (void)styleSeg:(UISegmentedControl *)s {
    if (@available(iOS 13, *)) {
        s.selectedSegmentTintColor = CH_ACCENT;
        s.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
        [s setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
        [s setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateSelected];
    }
    [s setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
}

- (UISwitch *)switchOn:(BOOL)on sel:(SEL)sel {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on; sw.onTintColor = CH_ACCENT;
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (CHPad *)chip:(NSString *)t color:(UIColor *)col {
    CHPad *p = [[CHPad alloc] init];
    p.text = t; p.font = [UIFont boldSystemFontOfSize:13];
    p.textColor = UIColor.whiteColor; p.textAlignment = NSTextAlignmentCenter;
    p.backgroundColor = [col colorWithAlphaComponent:0.9];
    p.layer.cornerRadius = 8; p.clipsToBounds = YES;
    return p;
}

- (UIButton *)bigBtn:(NSString *)t color:(UIColor *)col sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = col; b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:48].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)smallBtn:(NSString *)t sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1]; b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)statsCard {
    UIView *c = [[UIView alloc] init];
    c.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    c.layer.cornerRadius = 14;
    UIView *content;
    if (!(gTrackQuality && gAccCount > 0)) {
        content = [self lbl:(gTrackQuality ? @"Play a move and your accuracy + move grades appear here."
                                           : @"Move Analysis is off — turn it on below to grade your moves.")
                       size:13 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1]];
    } else {
        double acc = gAccSum / gAccCount;
        UIColor *accCol = acc >= 90 ? CH_ACCENT : (acc >= 75 ? [UIColor systemYellowColor] : [UIColor systemOrangeColor]);
        UILabel *big = [self lbl:[NSString stringWithFormat:@"%.0f%%", acc] size:40 weight:UIFontWeightHeavy color:accCol];
        UILabel *cap = [self lbl:[NSString stringWithFormat:@"Accuracy · %d moves", gAccCount] size:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1]];
        UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[big, cap]];
        top.axis = UILayoutConstraintAxisVertical; top.alignment = UIStackViewAlignmentLeading;

        UIStackView *breakdown = [[UIStackView alloc] init];
        breakdown.axis = UILayoutConstraintAxisVertical; breakdown.spacing = 6;
        for (int i = 0; i < Q_COUNT; i++) {
            CHPad *sym = [self chip:qSymbol(i) color:qColor(i)];
            [sym setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *name = [self lbl:qName(i) size:13 weight:UIFontWeightMedium color:UIColor.whiteColor];
            UIStackView *left = [[UIStackView alloc] initWithArrangedSubviews:@[sym, name]];
            left.axis = UILayoutConstraintAxisHorizontal; left.spacing = 8; left.alignment = UIStackViewAlignmentCenter;
            [left setContentHuggingPriority:250 forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *cnt = [self lbl:[NSString stringWithFormat:@"%d  (%.0f%%)", gQ[i],
                                      gAccCount ? gQ[i] * 100.0 / gAccCount : 0]
                                 size:13 weight:UIFontWeightSemibold color:qColor(i)];
            cnt.textAlignment = NSTextAlignmentRight;
            [cnt setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
            UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[left, cnt]];
            row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionFill;
            [breakdown addArrangedSubview:row];
        }

        NSMutableArray *parts = [@[top, breakdown] mutableCopy];
        if (gLastMoveQuality.length)
            [parts addObject:[self lbl:[@"Last move: " stringByAppendingString:gLastMoveQuality]
                                   size:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:0.75 alpha:1]]];
        UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:parts];
        col.axis = UILayoutConstraintAxisVertical; col.spacing = 12;
        content = col;
    }
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:c.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-14],
        [content.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-14]]];
    return c;
}

- (void)build {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 24; card.layer.masksToBounds = YES;
    if (@available(iOS 11, *)) card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [self addSubview:card];
    _card = card;

    UIView *grab = [[UIView alloc] init];
    grab.translatesAutoresizingMaskIntoConstraints = NO;
    grab.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    grab.layer.cornerRadius = 2.5;
    [card.contentView addSubview:grab];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    _stack = stack;
    _scroll = scroll;

    CGFloat bottomPad = 16;
    if (@available(iOS 11, *)) bottomPad += self.safeAreaInsets.bottom;
    CGFloat maxScroll = self.bounds.size.height * 0.85 - 22;

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [grab.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:8],
        [grab.centerXAnchor constraintEqualToAnchor:card.contentView.centerXAnchor],
        [grab.widthAnchor constraintEqualToConstant:40],
        [grab.heightAnchor constraintEqualToConstant:5],

        [scroll.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:22],
        [scroll.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-bottomPad],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20]]];

    NSLayoutConstraint *fit = [scroll.heightAnchor constraintEqualToAnchor:stack.heightAnchor constant:bottomPad];
    fit.priority = 750; fit.active = YES;
    NSLayoutConstraint *cap = [scroll.heightAnchor constraintLessThanOrEqualToConstant:maxScroll];
    cap.priority = 1000; cap.active = YES;

    [self populate];
}

- (void)populate {
    @try {
        for (UIView *v in [_stack.arrangedSubviews copy]) { [_stack removeArrangedSubview:v]; [v removeFromSuperview]; }

        UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
        [x setTitle:@"✕" forState:UIControlStateNormal];
        x.titleLabel.font = [UIFont systemFontOfSize:20];
        [x setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
        [x addTarget:self action:@selector(closeTap) forControlEvents:UIControlEventTouchUpInside];
        [x setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *hdr = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self lbl:@"Chess Assistant" size:22 weight:UIFontWeightBold color:UIColor.whiteColor], x]];
        hdr.axis = UILayoutConstraintAxisHorizontal; hdr.alignment = UIStackViewAlignmentCenter;
        [_stack addArrangedSubview:hdr];

        NSString *sub = [NSString stringWithFormat:@"%@ · Depth %ld · %@ · Playing %@",
            gEnabled ? @"Active" : @"Paused",
            (long)eloToDepth(gElo),
            gUseMaia ? @"Maia" : @"Stockfish",
            gMyColor == 0 ? @"White" : (gMyColor == 1 ? @"Black" : @"—")];
        UILabel *subLbl = [self lbl:sub size:13 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:0.75 alpha:1]];
        [_stack addArrangedSubview:subLbl];
        [_stack setCustomSpacing:12 afterView:hdr];

        NSString *eco = ecoName();
        if (eco.length) {
            UILabel *ecoLbl = [self lbl:[NSString stringWithFormat:@"📖 %@", eco]
                                   size:12 weight:UIFontWeightSemibold
                                  color:[UIColor colorWithRed:0.55 green:0.75 blue:0.95 alpha:1]];
            [_stack addArrangedSubview:ecoLbl];
            [_stack setCustomSpacing:10 afterView:subLbl];
        }

        UIView *stats = [self statsCard];
        [_stack addArrangedSubview:stats];

        // ---- ENGINE ----
        [_stack addArrangedSubview:[self sectionLabel:@"Engine"]];
        int eloCnt = 0; const NSInteger *eloLvls = activeEloLevels(&eloCnt);

        UISegmentedControl *engSeg = [[UISegmentedControl alloc] initWithItems:@[@"SF18", @"MAIA"]];
        engSeg.selectedSegmentIndex = gUseMaia ? 1 : 0;
        [self styleSeg:engSeg];
        [engSeg addTarget:self action:@selector(engSeg:) forControlEvents:UIControlEventValueChanged];

        _eloValue = [self lbl:[NSString stringWithFormat:@"%ld", (long)gElo] size:16 weight:UIFontWeightSemibold color:CH_ACCENT];
        NSString *tierText = gUseMaia
            ? [NSString stringWithFormat:@"%@ · tuned for Maia (%ld–%ld)", eloTierName(gElo), (long)eloLvls[0], (long)eloLvls[eloCnt-1]]
            : eloTierName(gElo);
        _eloTier  = [self lbl:tierText size:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1]];
        [_eloValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *elo = [[UISlider alloc] init];
        elo.minimumValue = 0; elo.maximumValue = eloCnt - 1; elo.value = activeEloNearestIndex(gElo);
        elo.minimumTrackTintColor = CH_ACCENT;
        [elo addTarget:self action:@selector(eloSlide:) forControlEvents:UIControlEventValueChanged];
        [elo addTarget:self action:@selector(eloDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        NSString *strengthTitle = gUseMaia ? @"Strength (Human-like)" : @"Strength (ELO)";
        UIStackView *eloHdr = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self lbl:strengthTitle size:15 weight:UIFontWeightMedium color:UIColor.whiteColor], _eloValue]];
        eloHdr.axis = UILayoutConstraintAxisHorizontal; eloHdr.distribution = UIStackViewDistributionFill;
        UIStackView *eloCol = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self rowTitle:@"Engine" control:engSeg], [self sep],
            eloHdr, [self sliderRow:elo], _eloTier]];
        eloCol.axis = UILayoutConstraintAxisVertical; eloCol.spacing = 8;
        [_stack addArrangedSubview:[self group:eloCol]];

        // ---- DISPLAY ----
        [_stack addArrangedSubview:[self sectionLabel:@"Display"]];

        UISegmentedControl *evalSeg = [[UISegmentedControl alloc] initWithItems:@[@"Centipawn", @"Win %"]];
        evalSeg.selectedSegmentIndex = gShowWinPct ? 1 : 0; [self styleSeg:evalSeg];
        [evalSeg addTarget:self action:@selector(evalSeg:) forControlEvents:UIControlEventValueChanged];
        UISegmentedControl *arrSeg = [[UISegmentedControl alloc] initWithItems:@[@"1", @"2", @"3"]];
        arrSeg.selectedSegmentIndex = MIN(2, MAX(0, (int)gArrowCount - 1)); [self styleSeg:arrSeg];
        [arrSeg addTarget:self action:@selector(arrSeg:) forControlEvents:UIControlEventValueChanged];
        UISegmentedControl *thickSeg = [[UISegmentedControl alloc] initWithItems:@[@"Thin", @"Med", @"Thick"]];
        thickSeg.selectedSegmentIndex = gArrowThick < 0.85 ? 0 : (gArrowThick > 1.2 ? 2 : 1); [self styleSeg:thickSeg];
        [thickSeg addTarget:self action:@selector(thickSeg:) forControlEvents:UIControlEventValueChanged];

        _opValue = [self lbl:[NSString stringWithFormat:@"%d%%", (int)round(gArrowAlpha * 100)]
                         size:15 weight:UIFontWeightSemibold color:CH_ACCENT];
        [_opValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *op = [[UISlider alloc] init];
        op.minimumValue = 0.3; op.maximumValue = 1.0; op.value = gArrowAlpha; op.minimumTrackTintColor = CH_ACCENT;
        [op addTarget:self action:@selector(opSlide:) forControlEvents:UIControlEventValueChanged];

        UIStackView *grp = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self rowTitle:@"Evaluation" control:evalSeg], [self sep],
            [self rowTitle:@"Arrows" control:arrSeg], [self sep],
            [self rowTitle:@"Thickness" control:thickSeg], [self sep],
            [self rowTitle:@"Eval Bar" control:[self switchOn:gShowEvalBar sel:@selector(swEvalBar:)]], [self sep],
            [self rowTitle:@"Opacity" control:_opValue],
            [self sliderRow:op]]];
        grp.axis = UILayoutConstraintAxisVertical; grp.spacing = 12;
        [_stack addArrangedSubview:[self group:grp]];

        // ---- FEATURES ----
        [_stack addArrangedSubview:[self sectionLabel:@"Features"]];

        NSMutableArray *swRows = [NSMutableArray array];
        [swRows addObject:[self rowTitle:@"Move Analysis" control:[self switchOn:gTrackQuality sel:@selector(swAnalysis:)]]];
        [swRows addObject:[self sep]];
        [swRows addObject:[self rowTitle:@"Eval Labels" control:[self switchOn:gShowEvalLabels sel:@selector(swLabels:)]]];
        [swRows addObject:[self sep]];
        [swRows addObject:[self rowTitle:@"Color by Eval" control:[self switchOn:gArrowEvalColor sel:@selector(swColor:)]]];
        UIStackView *sw = [[UIStackView alloc] initWithArrangedSubviews:swRows];
        sw.axis = UILayoutConstraintAxisVertical; sw.spacing = 14;
        [_stack addArrangedSubview:[self group:sw]];

        // ---- AUTO PLAY ----
        [_stack addArrangedSubview:[self sectionLabel:@"Auto Play"]];

        _apDelayValue = [self lbl:[NSString stringWithFormat:@"%.1fs", gAutoPlayDelay]
                             size:15 weight:UIFontWeightSemibold color:CH_ACCENT];
        [_apDelayValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *apDelay = [[UISlider alloc] init];
        apDelay.minimumValue = 0.0; apDelay.maximumValue = 5.0;
        apDelay.value = gAutoPlayDelay; apDelay.minimumTrackTintColor = CH_ACCENT;
        [apDelay addTarget:self action:@selector(apDelaySlide:) forControlEvents:UIControlEventValueChanged];
        [apDelay addTarget:self action:@selector(apDelayDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        _apJitterValue = [self lbl:[NSString stringWithFormat:@"±%.1fs", gAutoPlayJitterRange]
                              size:15 weight:UIFontWeightSemibold color:CH_ACCENT];
        [_apJitterValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *apJitter = [[UISlider alloc] init];
        apJitter.minimumValue = 0.0; apJitter.maximumValue = 2.0;
        apJitter.value = gAutoPlayJitterRange; apJitter.minimumTrackTintColor = CH_ACCENT;
        [apJitter addTarget:self action:@selector(apJitterSlide:) forControlEvents:UIControlEventValueChanged];
        [apJitter addTarget:self action:@selector(apJitterDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        _apSecondPctValue = [self lbl:[NSString stringWithFormat:@"%ld%%", (long)gAutoPlaySecondBestPct]
                     size:15 weight:UIFontWeightSemibold color:CH_ACCENT];
        [_apSecondPctValue setContentHuggingPriority:1000 forAxis:UILayoutConstraintAxisHorizontal];
        UISlider *apSecondPct = [[UISlider alloc] init];
        apSecondPct.minimumValue = 0.0; apSecondPct.maximumValue = 50.0;
        apSecondPct.value = gAutoPlaySecondBestPct; apSecondPct.minimumTrackTintColor = CH_ACCENT;
        [apSecondPct addTarget:self action:@selector(apSecondPctSlide:) forControlEvents:UIControlEventValueChanged];
        [apSecondPct addTarget:self action:@selector(apSecondPctDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        UIStackView *apCol = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self rowTitle:@"Auto Play" control:[self switchOn:gAutoPlay sel:@selector(swAutoPlay:)]],
            [self sep],
            [self rowTitle:@"Move Delay" control:_apDelayValue],
            [self sliderRow:apDelay],
            [self sep],
            [self rowTitle:@"Jitter" control:[self switchOn:gAutoPlayJitterEnabled sel:@selector(swAutoJitter:)]],
            [self rowTitle:@"Jitter Range" control:_apJitterValue],
            [self sliderRow:apJitter],
            [self sep],
            [self rowTitle:@"2nd Move Chance" control:[self switchOn:gAutoPlaySecondBest sel:@selector(swAutoSecondBest:)]],
            [self rowTitle:@"2nd Move %" control:_apSecondPctValue],
            [self sliderRow:apSecondPct],
            [self lbl:@"Wait after opponent's move before auto playing." size:11 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.5 alpha:1]]]];
        apCol.axis = UILayoutConstraintAxisVertical; apCol.spacing = 12;
        [_stack addArrangedSubview:[self group:apCol]];

        // ---- CONTROLS ----
        [_stack addArrangedSubview:[self sectionLabel:@"Controls"]];

        [_stack addArrangedSubview:[self bigBtn:(gEnabled ? @"Pause Assistant" : @"Enable Assistant")
                                          color:(gEnabled ? [UIColor systemRedColor] : CH_ACCENT)
                                            sel:@selector(enableTap)]];
        UIButton *prefBtn = [self smallBtn:@"⚡ Preferred Settings (Ban-Safe)" sel:@selector(preferredTap)];
        prefBtn.backgroundColor = [CH_ACCENT colorWithAlphaComponent:0.25];
        [_stack addArrangedSubview:prefBtn];
        UIStackView *copyRow = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self smallBtn:@"📋 Copy FEN" sel:@selector(copyFenTap)],
            [self smallBtn:@"📜 Copy PGN" sel:@selector(pgnTap)]]];
        copyRow.axis = UILayoutConstraintAxisHorizontal; copyRow.distribution = UIStackViewDistributionFillEqually; copyRow.spacing = 10;
        [_stack addArrangedSubview:copyRow];
        UIStackView *foot = [[UIStackView alloc] initWithArrangedSubviews:@[
            [self smallBtn:@"Debug Log" sel:@selector(debugTap)],
            [self smallBtn:@"Credits" sel:@selector(creditsTap)]]];
        foot.axis = UILayoutConstraintAxisHorizontal; foot.distribution = UIStackViewDistributionFillEqually; foot.spacing = 10;
        [_stack addArrangedSubview:foot];

        [_scroll setContentOffset:CGPointZero];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSMutableString *dump = [NSMutableString string];
            for (UIView *v in _stack.arrangedSubviews) {
                [dump appendFormat:@"[%@ %@] ", NSStringFromClass([v class]), NSStringFromCGRect(v.frame)];
            }
            dbg([NSString stringWithFormat:@"PANEL LAYOUT scroll=%@ stack=%@\n%@", NSStringFromCGRect(_scroll.frame), NSStringFromCGRect(_stack.frame), dump]);
        });
    } @catch (NSException *e) {
        dbg([NSString stringWithFormat:@"PANEL ERR: %@ — %@", e.name, e.reason]);
    }
}

- (void)eloSlide:(UISlider *)s {
    int i = (int)roundf(s.value); s.value = i;
    NSInteger e = activeEloForIndex(i);
    _eloValue.text = [NSString stringWithFormat:@"%ld%@", (long)e, (!gUseMaia && e > 1500) ? @" ⚠️" : @""];
    _eloTier.text = eloTierName(e);
}
- (void)eloDone:(UISlider *)s {
    gElo = activeEloForIndex((int)roundf(s.value));
    savePrefs(); gLastFen = nil;
    dbg([NSString stringWithFormat:@"ELO set to %ld (%@)", (long)gElo, gUseMaia ? @"maia" : @"stockfish"]);
    if (!gUseMaia && gElo > 1500) {
        UIAlertController *w = [UIAlertController alertControllerWithTitle:@"⚠️ Ban Risk"
            message:@"Playing above ~1500 strength is much easier for Chess.com's fair-play system to detect and greatly increases your ban risk. Lower ELO is safer."
            preferredStyle:UIAlertControllerStyleAlert];
        [w addAction:[UIAlertAction actionWithTitle:@"I understand" style:UIAlertActionStyleDestructive handler:nil]];
        [self.window.rootViewController presentViewController:w animated:YES completion:nil];
    }
}
- (void)evalSeg:(UISegmentedControl *)s { gShowWinPct = (s.selectedSegmentIndex == 1); savePrefs(); redrawArrows(); }
- (void)arrSeg:(UISegmentedControl *)s { gArrowCount = s.selectedSegmentIndex + 1; savePrefs(); gLastFen = nil; }
- (void)thickSeg:(UISegmentedControl *)s {
    gArrowThick = s.selectedSegmentIndex == 0 ? 0.7 : (s.selectedSegmentIndex == 2 ? 1.4 : 1.0);
    savePrefs(); redrawArrows();
}
- (void)swEvalBar:(UISwitch *)s {
    gShowEvalBar = s.on; savePrefs();
    if (!gShowEvalBar) removeEvalBar(); else updateEvalBar();
    dbg([NSString stringWithFormat:@"eval bar: %@", gShowEvalBar ? @"ON" : @"OFF"]);
}
- (void)opSlide:(UISlider *)s {
    gArrowAlpha = s.value; savePrefs(); redrawArrows();
    _opValue.text = [NSString stringWithFormat:@"%d%%", (int)round(s.value * 100)];
}
- (void)swAnalysis:(UISwitch *)s { gTrackQuality = s.on; savePrefs(); if (!s.on) resetAccuracy(); [self populate]; }
- (void)swLabels:(UISwitch *)s { gShowEvalLabels = s.on; savePrefs(); redrawArrows(); }
- (void)swColor:(UISwitch *)s { gArrowEvalColor = s.on; savePrefs(); redrawArrows(); }
- (void)engSeg:(UISegmentedControl *)s {
    gUseMaia = (s.selectedSegmentIndex == 1);
    clampGeloToActiveRange();
    savePrefs(); gLastFen = nil;
    if (gUseMaia) ensureMaiaLoaded();
    dbg([NSString stringWithFormat:@"engine: %@ — strength range %@", gUseMaia ? @"MAIA" : @"SF18",
         gUseMaia ? @"900–2000 (human-like)" : @"400–3500"]);
    [self populate];
}
- (void)swAutoPlay:(UISwitch *)s {
    gAutoPlay = s.on; savePrefs();
    dbg([NSString stringWithFormat:@"Auto play: %@", gAutoPlay ? @"ON" : @"OFF"]);
    if (!gAutoPlay) gLastAutoPlayed = nil;
}
- (void)swAutoJitter:(UISwitch *)s {
    gAutoPlayJitterEnabled = s.on;
    savePrefs();
}
- (void)swAutoSecondBest:(UISwitch *)s {
    gAutoPlaySecondBest = s.on;
    savePrefs();
}
- (void)apDelaySlide:(UISlider *)s {
    double v = round(s.value * 10.0) / 10.0; s.value = v;
    _apDelayValue.text = [NSString stringWithFormat:@"%.1fs", v];
}
- (void)apDelayDone:(UISlider *)s {
    gAutoPlayDelay = round(s.value * 10.0) / 10.0;
    savePrefs();
    dbg([NSString stringWithFormat:@"Auto play delay: %.1fs", gAutoPlayDelay]);
}
- (void)apJitterSlide:(UISlider *)s {
    double v = round(s.value * 10.0) / 10.0; s.value = v;
    _apJitterValue.text = [NSString stringWithFormat:@"±%.1fs", v];
}
- (void)apJitterDone:(UISlider *)s {
    gAutoPlayJitterRange = round(s.value * 10.0) / 10.0;
    if (gAutoPlayJitterRange < 0) gAutoPlayJitterRange = 0;
    if (gAutoPlayJitterRange > 2.0) gAutoPlayJitterRange = 2.0;
    savePrefs();
}
- (void)apSecondPctSlide:(UISlider *)s {
    NSInteger v = (NSInteger)lround(s.value);
    if (v < 0) v = 0;
    if (v > 50) v = 50;
    s.value = (float)v;
    _apSecondPctValue.text = [NSString stringWithFormat:@"%ld%%", (long)v];
}
- (void)apSecondPctDone:(UISlider *)s {
    NSInteger v = (NSInteger)lround(s.value);
    if (v < 0) v = 0;
    if (v > 50) v = 50;
    gAutoPlaySecondBestPct = v;
    savePrefs();
}
- (void)pgnTap {
    NSString *pgn = buildPGN();
    if (!pgn.length) {
        showQualityToast(@"No game moves yet", [UIColor systemOrangeColor]);
        return;
    }
    [UIPasteboard generalPasteboard].string = pgn;
    showQualityToast(@"📜 PGN copied", CH_ACCENT);
}
- (void)copyFenTap {
    NSString *fen = gLastFen;
    if (!fen.length) {
        showQualityToast(@"No position yet", [UIColor systemOrangeColor]);
        return;
    }
    [UIPasteboard generalPasteboard].string = fen;
    showQualityToast(@"FEN copied", CH_ACCENT);
    dbg([NSString stringWithFormat:@"copied FEN: %@", fen]);
}
- (void)preferredTap {
    gArrowCount   = 3;
    gArrowAlpha   = 0.3;
    gShowWinPct   = YES;
    gArrowThick   = 0.7;
    gUseMaia      = YES;
    gAutoPlay     = NO;
    gAutoPlayJitterEnabled = NO;
    gAutoPlayJitterRange = 1.0;
    gAutoPlaySecondBest = NO;
    gAutoPlaySecondBestPct = 10;
    gElo          = 1000;
    gLastFen      = nil;
    gLastAutoPlayed = nil;
    savePrefs();
    resetAccuracy();
    dbg(@"preset: preferred (ban-safe) applied");
    showQualityToast(@"⚡ Ban-Safe Preset", CH_ACCENT);
    [self populate];
}
- (void)enableTap { gEnabled = !gEnabled; savePrefs(); if (!gEnabled) clearArrow(); [self populate]; }
- (void)debugTap {
    [self animateOut];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ showDebugLog(); });
}
- (void)creditsTap {
    [self animateOut];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ showCredits(); });
}
- (void)closeTap { [self animateOut]; }

- (void)animateIn {
    [self layoutIfNeeded];
    CGFloat h = _card.frame.size.height > 0 ? _card.frame.size.height : 420;
    _card.transform = CGAffineTransformMakeTranslation(0, h);
    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:0 animations:^{
        _card.transform = CGAffineTransformIdentity;
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    } completion:nil];
}
- (void)animateOut {
    CGFloat h = _card.frame.size.height > 0 ? _card.frame.size.height : 420;
    [UIView animateWithDuration:0.26 animations:^{
        _card.transform = CGAffineTransformMakeTranslation(0, h);
        self.backgroundColor = [UIColor clearColor];
    } completion:^(BOOL f) {
        [self removeFromSuperview];
        gMenuWin.hidden = YES;
        [[UIApplication sharedApplication].delegate.window makeKeyWindow];
    }];
}
@end

static void showSettingsMenu(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [CHSettingsPanel show]; });
}

static void updateFloatBtn(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gFloatBtn) return;
        [gFloatBtn setTitle:text forState:UIControlStateNormal];

        CGFloat w = (text.length > 2) ? 56 : 40;
        CGFloat h = 32;
        CGRect f = gFloatBtn.frame;
        gFloatBtn.frame = CGRectMake(f.origin.x, f.origin.y, w, h);
        gFloatBtn.titleLabel.font = (text.length > 2)
            ? [UIFont boldSystemFontOfSize:13]
            : [UIFont systemFontOfSize:20];
    });
}

static void showQualityToast(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gFloatBtn || !gBtnWin) return;
        UILabel *toast = [[UILabel alloc] init];
        toast.text = text;
        toast.font = [UIFont boldSystemFontOfSize:13];
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [(color ?: [UIColor darkGrayColor]) colorWithAlphaComponent:0.92];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.layer.cornerRadius = 9;
        toast.clipsToBounds = YES;
        [toast sizeToFit];
        CGFloat w = toast.bounds.size.width + 20, h = 24;
        CGPoint c = gFloatBtn.center;
        toast.frame = CGRectMake(c.x - w / 2, c.y - 40, w, h);
        toast.alpha = 0;
        [gBtnWin addSubview:toast];
        [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; }];
        [UIView animateWithDuration:0.3 delay:1.6 options:0
            animations:^{ toast.alpha = 0; }
            completion:^(BOOL fin) { [toast removeFromSuperview]; }];
    });
}

static BOOL isBoardOnScreen(UIView *v) {
    if (!v) return NO;
    UIWindow *w = v.window;
    if (!w) return NO;
    if (v.hidden || v.alpha < 0.05) return NO;
    UIView *a = v.superview;
    for (int g = 0; a && g < 40; g++) {
        if (a.hidden || a.alpha < 0.05) return NO;
        a = a.superview;
    }
    CGRect inWin = [v convertRect:v.bounds toView:nil];
    CGRect inter = CGRectIntersection(inWin, w.bounds);
    if (CGRectIsNull(inter)) return NO;
    CGFloat ownArea = v.bounds.size.width * v.bounds.size.height;
    if (ownArea <= 1) return NO;
    CGFloat visArea = inter.size.width * inter.size.height;
    return (visArea / ownArea) > 0.5;
}

#pragma mark - Eval Bar (horizontal, above board)

static NSMutableArray *gEvalBarLayers = nil;

static void removeEvalBar(void) {
    for (CALayer *l in gEvalBarLayers) [l removeFromSuperlayer];
    [gEvalBarLayers removeAllObjects];
}

static void updateEvalBar(void) {
    removeEvalBar();
    UIView *board = gDrawBoard ?: gBoardView ?: gBotBoard;
    if (!gShowEvalBar || !gBarHave || !board || !board.window || !isBoardOnScreen(board)) return;

    CGFloat barH = 16;
    CGRect bF = board.bounds;
    if (bF.size.width < 60) return;
    BOOL masked = board.layer.masksToBounds;

    // horizontal bar sitting above the board, raised by an extra bar-height so
    // it never touches the top rank; falls back to an overlay pinned inside
    // the top edge if the board clips its own layer
    CGRect bar = CGRectMake(2, masked ? 3 : -(barH * 2 + 6), bF.size.width - 4, barH);

    double frac = 0.5;
    NSString *txt;
    if (gBarIsMate) {
        BOOL whiteMates = gBarMateWhite > 0;
        frac = whiteMates ? 0.95 : 0.05;
        txt = [NSString stringWithFormat:@"%@M%d", whiteMates ? @"" : @"-", abs(gBarMateWhite)];
    } else {
        double wp = evalToWinPct(gBarWhiteEval, NO, 0);
        frac = MIN(0.97, MAX(0.03, wp / 100.0));
        txt = [NSString stringWithFormat:@"%+.1f", gBarWhiteEval];
    }
    UIColor *txtColor = frac >= 0.5 ? UIColor.blackColor : UIColor.whiteColor;

    if (!gEvalBarLayers) gEvalBarLayers = [NSMutableArray array];

    CALayer *bg = [CALayer layer];
    bg.frame = bar;
    bg.backgroundColor = [UIColor colorWithWhite:0.13 alpha:0.94].CGColor;
    bg.cornerRadius = 4;
    bg.zPosition = 10005;

    CALayer *fill = [CALayer layer];
    fill.frame = CGRectMake(1, 1, MAX(2, (bar.size.width - 2) * frac), barH - 2);
    fill.backgroundColor = [UIColor whiteColor].CGColor;
    fill.cornerRadius = 3;
    fill.zPosition = 10006;

    CATextLayer *tl = [CATextLayer layer];
    tl.frame = bar;
    tl.string = txt;
    tl.fontSize = 11;
    tl.alignmentMode = kCAAlignmentCenter;
    tl.foregroundColor = txtColor.CGColor;
    tl.contentsScale = [UIScreen mainScreen].scale;
    tl.zPosition = 10007;

    [board.layer addSublayer:bg];
    [board.layer addSublayer:fill];
    [board.layer addSublayer:tl];
    [gEvalBarLayers addObjectsFromArray:@[bg, fill, tl]];
}

static BOOL detectBoardFlipped(UIView *board) {
    if (gForcedFlip >= 0) return gForcedFlip ? YES : NO;
    @try {
        SEL flipSel = NSSelectorFromString(@"isFlipped");
        if ([board respondsToSelector:flipSel]) {
            typedef BOOL (*BoolGetter)(id, SEL);
            return ((BoolGetter)objc_msgSend)(board, flipSel) ? YES : NO;
        }
        Ivar ivar = class_getInstanceVariable([board class], "_flipped");
        if (!ivar) ivar = class_getInstanceVariable([board class], "isFlipped");
        if (ivar) {
            ptrdiff_t offset = ivar_getOffset(ivar);
            return *(BOOL *)((char *)(__bridge void *)board + offset) ? YES : NO;
        }
    } @catch (NSException *e) {
        dbg([NSString stringWithFormat:@"flip detect err: %@", e.reason]);
    }
    return NO;
}

#pragma mark - Auto Play (synthetic touches)

static void setMyColor(NSInteger c, NSString *src) {
    if (gMyColor != c) {
        dbg([NSString stringWithFormat:@"COLOR %ld -> %ld  (%@)", (long)gMyColor, (long)c, src]);
    }
    gMyColor = c;
}

static int fenSideToMove(NSString *fen) {
    NSArray *parts = [fen componentsSeparatedByString:@" "];
    if (parts.count < 2) return -1;
    NSString *f = [parts[1] lowercaseString];
    if ([f isEqualToString:@"b"]) return 1;
    if ([f isEqualToString:@"w"]) return 0;
    return -1;
}


static NSMutableArray *gFakeTouches = nil;

static NSMutableSet *sDumpedClasses = nil;

static void dumpMoveSelectors(id obj, NSString *tag) {
    if (!obj) return;
    Class c = object_getClass(obj);
    if (!c) return;
    if (!sDumpedClasses) sDumpedClasses = [NSMutableSet set];
    NSString *key = [tag stringByAppendingString:NSStringFromClass(c)];
    if ([sDumpedClasses containsObject:key]) return;
    [sDumpedClasses addObject:key];

    NSArray *keywords = @[@"move", @"play", @"tap", @"touch", @"piece",
                          @"select", @"square", @"drag", @"click", @"perform"];
    unsigned int n = 0;
    Method *methods = class_copyMethodList(c, &n);
    if (methods) {
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < n && hits.count < 50; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            for (NSString *k in keywords) {
                if ([lower containsString:k]) { [hits addObject:name]; break; }
            }
        }
        free(methods);
        if (hits.count)
            dbg([NSString stringWithFormat:@"DUMP[%@] %@ (%lu): %@", tag, NSStringFromClass(c),
                 (unsigned long)hits.count, [hits componentsJoinedByString:@", "]]);
    }

    Class meta = object_getClass(c);
    unsigned int cn = 0;
    Method *cmethods = class_copyMethodList(meta, &cn);
    if (cmethods) {
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned int i = 0; i < cn && hits.count < 30; i++) {
            NSString *name = NSStringFromSelector(method_getName(cmethods[i]));
            NSString *lower = name.lowercaseString;
            for (NSString *k in keywords) {
                if ([lower containsString:k]) { [hits addObject:name]; break; }
            }
        }
        free(cmethods);
        if (hits.count)
            dbg([NSString stringWithFormat:@"DUMP[%@] +(%@): %@", tag,
                 NSStringFromClass(c), [hits componentsJoinedByString:@", "]]);
    }
}

static UITouch *chAcquireFakeTouch(void) {
    if (!gFakeTouches) gFakeTouches = [NSMutableArray array];
    UITouch *t = gFakeTouches.firstObject;
    if (!t) {
        t = [[UITouch alloc] init];
        [gFakeTouches addObject:t];
    }
    return t;
}

static void chSetKvc(id obj, NSString *key, id val) {
    @try {
        [obj setValue:val forKey:key];
    } @catch (NSException *e) {
        static NSMutableSet *sWarnedKeys = nil;
        if (!sWarnedKeys) sWarnedKeys = [NSMutableSet set];
        if (![sWarnedKeys containsObject:key]) {
            [sWarnedKeys addObject:key];
            dbg([NSString stringWithFormat:@"autoplay: UITouch key '%@' unsupported, skipped", key]);
        }
    }
}

static void chFakeTouchFire(CGPoint ptInWin, UIWindow *win, UITouchPhase phase) {
    @try {
        UITouch *touch = chAcquireFakeTouch();
        chSetKvc(touch, @"_phase", @(phase));
        chSetKvc(touch, @"_locationInWindow", [NSValue valueWithCGPoint:ptInWin]);
        chSetKvc(touch, @"_tapCount", @1);
        chSetKvc(touch, @"_timestamp", @(NSDate.date.timeIntervalSince1970));
        chSetKvc(touch, @"_window", win);

        UIView *target = [win hitTest:ptInWin withEvent:nil] ?: win;
        chSetKvc(touch, @"_view", target);

        static UIEvent *sCarrierEvent = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sCarrierEvent = [[UIEvent alloc] init]; });

        NSSet *touches = [NSSet setWithObject:touch];
        switch (phase) {
            case UITouchPhaseBegan:
                [target touchesBegan:touches withEvent:sCarrierEvent];
                break;
            case UITouchPhaseMoved:
                [target touchesMoved:touches withEvent:sCarrierEvent];
                break;
            case UITouchPhaseCancelled:
                [target touchesCancelled:touches withEvent:sCarrierEvent];
                break;
            default:
                [target touchesEnded:touches withEvent:sCarrierEvent];
                break;
        }
    } @catch (NSException *e) {
        dbg([NSString stringWithFormat:@"autoplay touch err: %@", e.reason]);
    }
}

static BOOL playMoveOnBoard(NSString *uci, NSString *fenSnap, UIView *preferredBoard) {
    if (!gEnabled || !gAutoPlay) return NO;
    if (![fenSnap isEqualToString:gLastFen]) return NO;

    UIView *board = preferredBoard;
    if (!board || !board.window || !isBoardOnScreen(board)) {
        board = gDrawBoard ?: gBoardView ?: gBotBoard;
    }
    if (!board || !board.window || !isBoardOnScreen(board)) { dbg(@"autoplay: no board"); return NO; }

    int fromSq = 0, toSq = 0;
    if (!parseMoveUCI(uci, &fromSq, &toSq)) { dbg(@"autoplay: bad move"); return NO; }

    BOOL flipped = detectBoardFlipped(board);
    CGRect winRect = [board convertRect:board.bounds toView:nil];
    UIWindow *win = board.window;

    CGPoint fromLocal = squareToPoint(fromSq, board.bounds, flipped);
    CGPoint toLocal   = squareToPoint(toSq,   board.bounds, flipped);
    CGPoint fromWin = CGPointMake(winRect.origin.x + fromLocal.x, winRect.origin.y + fromLocal.y);
    CGPoint toWin   = CGPointMake(winRect.origin.x + toLocal.x,   winRect.origin.y + toLocal.y);

    BOOL promo = uci.length > 4;
    CGPoint promoWin = CGPointZero;
    if (promo) {
        int mover = fenSideToMove(fenSnap);
        if (mover < 0) mover = gSide;
        int qSq = (mover == 1) ? toSq + 8 : toSq - 8;
        if (qSq < 0 || qSq > 63) qSq = toSq;
        CGPoint qLocal = squareToPoint(qSq, board.bounds, flipped);
        promoWin = CGPointMake(winRect.origin.x + qLocal.x, winRect.origin.y + qLocal.y);
    }

    dbg([NSString stringWithFormat:@"autoplay: %@", uci]);
    showQualityToast(@"▶ Auto Play", CH_ACCENT);

    chFakeTouchFire(fromWin, win, UITouchPhaseBegan);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        chFakeTouchFire(fromWin, win, UITouchPhaseEnded);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            chFakeTouchFire(toWin, win, UITouchPhaseBegan);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                chFakeTouchFire(toWin, win, UITouchPhaseEnded);
                if (promo) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        chFakeTouchFire(promoWin, win, UITouchPhaseBegan);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            chFakeTouchFire(promoWin, win, UITouchPhaseEnded);
                        });
                    });
                }
            });
        });
    });
    return YES;
}

static void tryAutoPlay(NSString *bestmove, NSString *altMove, NSString *fenSnap, UIView *preferredBoard) {
    if (!gAutoPlay || !gEnabled) return;
    if (gPuzzleCtx) return;
    if (bestmove.length < 4) return;
    if (!fenSnap.length || [fenSnap isEqualToString:gLastAutoPlayed]) return;

    if (gMyColor < 0) { dbg(@"autoplay: color unknown, skip"); return; }
    int snapSide = fenSideToMove(fenSnap);
    if (snapSide < 0 || snapSide != gMyColor) { dbg(@"autoplay: not our turn, skip"); return; }

    NSString *chosen = bestmove;
    if (gAutoPlaySecondBest && altMove.length >= 4 && ![altMove isEqualToString:bestmove]) {
        uint32_t chance = (uint32_t)MAX(0, MIN(100, (int)gAutoPlaySecondBestPct));
        if (chance > 0 && arc4random_uniform(100) < chance) chosen = altMove;
    }

    double delay = gAutoPlayDelay;
    if (gAutoPlayJitterEnabled && gAutoPlayJitterRange > 0.0) {
        double r = gAutoPlayJitterRange;
        double jit = ((double)arc4random_uniform(2001) / 1000.0 - 1.0) * r;
        delay += jit;
    }
    if (delay < 0.0) delay = 0.0;
    if (delay > 6.0) delay = 6.0;

    __block int retries = 0;
    __block void (^attempt)(void) = nil;
    __weak void (^weakAttempt)(void) = nil;
    attempt = ^{
        if (!gAutoPlay || !gEnabled) return;
        if (![fenSnap isEqualToString:gLastFen]) return;
        if ([fenSnap isEqualToString:gLastAutoPlayed]) return;
        if (gMyColor < 0 || snapSide != gMyColor) return;
        if (playMoveOnBoard(chosen, fenSnap, preferredBoard)) {
            gLastAutoPlayed = [fenSnap copy];
            return;
        }
        retries++;
        if (retries < 15) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), weakAttempt);
        }
    };
    weakAttempt = attempt;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), weakAttempt);
}

static void applyEngineResult(NSString *bestmove, NSArray *extraMoves, BOOL isMate, int mateIn,
                              double rawEval, UIView *drawBoard) {

    double evalForUs = rawEval;
    if (gMyColor == 1) evalForUs = -rawEval;
    if (isMate && gMyColor == 1) mateIn = -mateIn;

    gLastEval = isMate ? (mateIn > 0 ? 999 : -999) : evalForUs;
    gHasEval = YES;

    // eval bar data (white perspective)
    gBarWhiteEval = rawEval;
    gBarIsMate = isMate;
    gBarMateWhite = isMate ? ((gMyColor == 1) ? -mateIn : mateIn) : 0;
    gBarHave = YES;

    NSString *evalStr = @"";
    NSString *btnText = @"♟";
    if (isMate) {
        evalStr = [NSString stringWithFormat:@" M%d", abs(mateIn)];
        btnText = [NSString stringWithFormat:@"M%d", abs(mateIn)];
    } else if (gShowWinPct) {
        double wp = evalToWinPct(evalForUs, NO, 0);
        evalStr = [NSString stringWithFormat:@" %.0f%%", wp];
        btnText = [NSString stringWithFormat:@"%.0f%%", wp];
    } else {
        evalStr = [NSString stringWithFormat:@" %+.1f", evalForUs];
        btnText = [NSString stringWithFormat:@"%+.1f", evalForUs];
    }

    dbg([NSString stringWithFormat:@"suggest: %@%@", bestmove, evalStr]);
    updateFloatBtn(btnText);

    UIView *board = drawBoard;
    NSString *altMove = nil;
    if (extraMoves.count > 0) {
        NSDictionary *c = extraMoves.firstObject;
        if ([c isKindOfClass:[NSDictionary class]]) altMove = c[@"move"];
    }
    if (!board || !board.window) board = gDrawBoard ?: gBoardView;
    if (board) {
        BOOL flipped = detectBoardFlipped(board);
        double arrowEval = isMate ? (mateIn > 0 ? 99 : -99) : evalForUs;
        NSMutableArray *arrows = [NSMutableArray array];
        [arrows addObject:@{@"move": bestmove, @"eval": @(arrowEval), @"rank": @0,
                            @"label": formatEvalLabel(evalForUs, isMate, mateIn)}];
        int rank = 1;
        for (NSDictionary *c in extraMoves) {
            if (rank >= gArrowCount) break;
            [arrows addObject:@{@"move": c[@"move"], @"eval": @(arrowEval), @"rank": @(rank),
                                @"label": c[@"label"] ?: @""}];
            rank++;
        }
        drawArrowsOnBoard(arrows, board, flipped);
        updateEvalBar();
    } else {
        dbg(@"no board ref for arrow");
    }
    tryAutoPlay(bestmove, altMove, gLastFen, board);
}

static BOOL fenHasBothKings(NSString *fen) {
    NSString *place = [[fen componentsSeparatedByString:@" "] firstObject];
    int K = 0, k = 0;
    for (NSUInteger i = 0; i < place.length; i++) {
        unichar c = [place characterAtIndex:i];
        if (c == 'K') K++; else if (c == 'k') k++;
    }
    return K == 1 && k == 1;
}

static NSArray<NSString *> *maiaCandidatePaths(void) {
    NSMutableArray *c = [@[
        @"/var/jb/Library/Application Support/Chess/maia3_5m.mlpackage",
        @"/Library/Application Support/Chess/maia3_5m.mlpackage",
    ] mutableCopy];
    NSString *res = [[NSBundle mainBundle] resourcePath];
    if (res) {
        [c addObject:[res stringByAppendingPathComponent:@"maia3_5m.mlpackage"]];
        [c addObject:[res stringByAppendingPathComponent:@"Chess/maia3_5m.mlpackage"]];
    }
    // resolve the real jailbreak root via /private/preboot if /var/jb is unreadable from the app sandbox
    @try {
        NSArray *uuids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/private/preboot" error:nil];
        for (NSString *uuid in uuids) {
            NSString *base = [@"/private/preboot/" stringByAppendingString:uuid];
            NSArray *subs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
            for (NSString *s in subs) {
                if (![s hasPrefix:@"jb-"]) continue;
                [c addObject:[[base stringByAppendingPathComponent:s]
                    stringByAppendingPathComponent:@"Library/Application Support/Chess/maia3_5m.mlpackage"]];
            }
        }
    } @catch (NSException *e) {}
    return c;
}

static BOOL sMaiaRetryDone = NO;

static BOOL isInitialStartFEN(NSString *fen) {
    if (!fen.length) return NO;
    return [fen hasPrefix:@"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w "];
}

static void ensureMaiaLoaded(void) {
    if (MaiaAvailable()) return;
    if (sMaiaRetryDone) return;
    sMaiaRetryDone = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *c in maiaCandidatePaths()) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:c]) {
                BOOL ok = MaiaLoad([c UTF8String]);
                dbg([NSString stringWithFormat:@"maia retry load %@: %@", ok ? @"OK" : @"FAIL", c]);
                if (ok) return;
            }
        }
        // filesystem lookup failed (sandboxed app can't see /var/jb) — use the model embedded in our dylib
        BOOL ok = MaiaLoadEmbedded();
        dbg([NSString stringWithFormat:@"maia embedded load: %@", ok ? @"OK" : @"FAIL"]);
    });
}

// SAN for one UCI move in the given position: board state gives piece/capture,
// Stockfish legal-move enumeration handles disambiguation.
static NSString *sanForMove(NSString *fen, NSString *uci) {
    parseFEN(fen);
    int from = 0, to = 0;
    if (!parseMoveUCI(uci, &from, &to)) return nil;
    if (from < 0 || from > 63 || to < 0 || to > 63) return nil;
    char piece = gBoard[from];
    if (piece == ' ') return nil;
    char up = (char)toupper((unsigned char)piece);

    if (up == 'K' && abs((to % 8) - (from % 8)) == 2)
        return (to % 8 == 6) ? @"O-O" : @"O-O-O";

    BOOL isPawn = (up == 'P');
    BOOL capture = (gBoard[to] != ' ');
    if (!capture && isPawn && to == gEp) capture = YES;

    NSMutableString *san = [NSMutableString string];
    if (!isPawn) [san appendFormat:@"%c", up];
    else if (capture) [san appendFormat:@"%c", 'a' + (from % 8)];

    if (!isPawn && up != 'K') {
        char buf[256 * 6];
        int n = StockfishLegalMoves([fen UTF8String], buf, 256);
        BOOL anyOther = NO, sameFile = NO, sameRank = NO;
        for (int i = 0; i < n; i++) {
            NSString *m = [NSString stringWithFormat:@"%s", buf + i * 6];
            int f2 = 0, t2 = 0;
            if (!parseMoveUCI(m, &f2, &t2)) continue;
            if (f2 == from || t2 != to) continue;
            if (gBoard[f2] != piece) continue;
            anyOther = YES;
            if ((f2 % 8) == (from % 8)) sameFile = YES;
            if ((f2 / 8) == (from / 8)) sameRank = YES;
        }
        if (anyOther) {
            if (!sameFile)      [san appendFormat:@"%c", 'a' + (from % 8)];
            else if (!sameRank) [san appendFormat:@"%c", '1' + (from / 8)];
            else                [san appendFormat:@"%c%c", 'a' + (from % 8), '1' + (from / 8)];
        }
    }

    if (capture) [san appendString:@"x"];
    [san appendFormat:@"%c%c", 'a' + (to % 8), '1' + (to / 8)];
    char promo = (uci.length > 4) ? (char)toupper([uci characterAtIndex:4]) : 0;
    if (promo) [san appendFormat:@"=%c", promo];
    return san;
}

static NSString *buildPGN(void) {
    if (!gUciSeq.length || !gPgnStartFen.length) return nil;

    NSArray *tokens = [gUciSeq componentsSeparatedByString:@" "];
    NSMutableArray *sans = [NSMutableArray array];

    parseFEN(gPgnStartFen);
    NSInteger moveNo = gFull;
    BOOL blackFirst = (gSide == 1);

    for (NSString *tok in tokens) {
        if (tok.length < 4) continue;
        NSString *fen = generateFEN();
        NSString *san = sanForMove(fen, tok);
        if (!san.length) return nil;
        [sans addObject:san];
        int from = 0, to = 0;
        parseMoveUCI(tok, &from, &to);
        char promo = (tok.length > 4) ? (char)tolower([tok characterAtIndex:4]) : 0;
        applyMove(from, to, promo);
    }
    if (!sans.count) return nil;

    NSMutableString *body = [NSMutableString string];
    NSInteger n = moveNo;
    if (!blackFirst) {
        for (NSUInteger i = 0; i < sans.count; i += 2) {
            [body appendFormat:@"%@%@. %@", body.length ? @" " : @"", @(n++), sans[i]];
            if (i + 1 < sans.count) [body appendFormat:@" %@", sans[i + 1]];
        }
    } else {
        [body appendFormat:@"%ld... %@", (long)n, sans[0]];
        for (NSUInteger i = 1; i < sans.count; i += 2) {
            [body appendFormat:@" %ld. %@", ++n, sans[i]];
            if (i + 1 < sans.count) [body appendFormat:@" %@", sans[i + 1]];
        }
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy.MM.dd";

    NSMutableString *pgn = [NSMutableString string];
    [pgn appendFormat:
        @"[Event \"Chess Assistant\"]\n"
         "[Site \"?\"]\n"
         "[Date \"%@\"]\n"
         "[Round \"?\"]\n"
         "[White \"?\"]\n"
         "[Black \"?\"]\n"
         "[Result \"*\"]\n",
        [df stringFromDate:[NSDate date]]];    NSString *startpos = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    if (![gPgnStartFen isEqualToString:startpos]) {
        [pgn appendFormat:@"[SetUp \"1\"]\n[FEN \"%@\"]\n", gPgnStartFen];
    }
    [pgn appendFormat:@"\n%@\n*\n", body];
    return pgn;
}

static int humanizedPickIndex(const EngineLine *lines, int count, int elo) {
    if (count < 2 || elo >= 2000) return 0;
    if (!lines[0].hasScore || lines[0].isMate) return 0;

    double T = (2000.0 - (double)elo) / 6.0;
    if (T < 1.0) return 0;
    double maxLoss = 60.0 + (2000.0 - (double)elo) * 0.60;
    if (maxLoss > 900.0) maxLoss = 900.0;

    int n = count > 8 ? 8 : count;
    double w[8]; double sum = 0;
    for (int i = 0; i < n; i++) {
        w[i] = 0;
        if (!lines[i].hasScore || lines[i].isMate) continue;
        double loss = (double)(lines[0].score - lines[i].score);
        if (loss < 0) loss = 0;
        if (loss > maxLoss) continue;
        w[i] = exp(-loss / T);
        sum += w[i];
    }
    if (sum <= 0) return 0;
    double r = ((double)arc4random_uniform(1000000) / 1000000.0) * sum;
    double acc = 0;
    for (int i = 0; i < n; i++) { acc += w[i]; if (w[i] > 0 && r <= acc) return i; }
    return 0;
}

static void fetchMove(NSString *fen) {
    if (!gEnabled || !fen.length) return;
    if (!fenHasBothKings(fen)) return;
    if (!StockfishFenLegal([fen UTF8String])) { dbg(@"skip illegal pos"); return; }
    if (isInitialStartFEN(fen)) gLastAutoPlayed = nil;
    if ([fen isEqualToString:gLastFen]) return;

    if (gFetching && gLastFetch && [[NSDate date] timeIntervalSinceDate:gLastFetch] > 5.0) {
        gFetching = NO;
    }
    if (gFetching) { gPendingFen = [fen copy]; return; }

    gLastFen = [fen copy];
    gFetching = YES;
    gLastFetch = [NSDate date];
    NSString *snap = [fen copy];

    __block UIView *drawBoard = gDrawBoard ?: gBoardView;

    BOOL stmWhite = ([fen rangeOfString:@" w "].location != NSNotFound);

    if (gUseMaia) ensureMaiaLoaded();
    if (gUseMaia && MaiaAvailable()) {
        dbg([NSString stringWithFormat:@"maia elo%ld: %@", (long)gElo,
             [fen substringToIndex:MIN(fen.length, 45)]]);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            MaiaGo([fen UTF8String], (int)gElo, (int)gElo, ^(MaiaResult r) {
                NSString *bm = r.ok ? [NSString stringWithUTF8String:r.move] : nil;
                double rawWhite = r.whiteEval;
                NSMutableArray *extras = [NSMutableArray array];
                for (int i = 1; i < r.count && i < gArrowCount; i++) {
                    [extras addObject:@{@"move": [NSString stringWithUTF8String:r.moves[i]],
                                        @"label": [NSString stringWithFormat:@"%.0f%%", r.policy[i] * 100.0]}];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    gFetching = NO;
                    if (gPendingFen && ![gPendingFen isEqualToString:gLastFen]) {
                        NSString *next = [gPendingFen copy];
                        gPendingFen = nil;
                        dispatch_async(dispatch_get_main_queue(), ^{ fetchMove(next); });
                    } else {
                        gPendingFen = nil;
                    }
                    if (![snap isEqualToString:gLastFen]) { dbg(@"stale resp"); return; }
                    if (!bm.length) { dbg(@"maia no move"); return; }
                    applyEngineResult(bm, extras, NO, 0, rawWhite, drawBoard);
                });
            });
        });

        if (gTrackQuality) {
            NSInteger gdepth = MAX(14, eloToDepth(gElo));
            EngineGo([fen UTF8String], (int)gdepth, (int)gElo, 2,
                     ^(const EngineLine *lines, int count) {
                BOOL hasScore = (count > 0) ? lines[0].hasScore : NO;
                BOOL lmate = (count > 0) ? lines[0].isMate : NO;
                int  lscore = (count > 0) ? lines[0].score : 0;
                double secondWhite = 0; BOOL have2nd = NO;
                if (count >= 2 && lines[1].hasScore && !lines[1].isMate) {
                    double cp = lines[1].score / 100.0;
                    secondWhite = stmWhite ? cp : -cp;
                    have2nd = YES;
                }
                double rawWhite = 0; BOOL mate = NO;
                if (hasScore) {
                    if (lmate) mate = YES;
                    else { double cp = lscore / 100.0; rawWhite = stmWhite ? cp : -cp; }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    noteUserEval(snap, mate ? 0 : rawWhite, !mate && hasScore, secondWhite, have2nd);
                });
            });
        }
        return;
    }

    NSInteger depth = eloToDepth(gElo);
    dbg([NSString stringWithFormat:@"fetch d%ld: %@", (long)depth,
         [fen substringToIndex:MIN(fen.length, 45)]]);

    int multipv = gTrackQuality ? MAX((int)gArrowCount, 2) : (int)gArrowCount;
    if (gElo < 1600) multipv = MAX(multipv, 8);
    else if (gElo < 2000) multipv = MAX(multipv, 4);
    EngineGo([fen UTF8String], (int)depth, (int)gElo, multipv,
             ^(const EngineLine *lines, int count) {

        int pick = (count > 0) ? humanizedPickIndex(lines, count, (int)gElo) : 0;
        if (pick > 0) dbg([NSString stringWithFormat:@"humanized: played #%d of %d", pick + 1, count]);
        NSString *bm = (count > 0) ? [NSString stringWithUTF8String:lines[pick].move] : nil;
        BOOL hasScore = (count > 0) ? lines[0].hasScore : NO;
        BOOL lmate = (count > 0) ? lines[0].isMate : NO;
        int  lscore = (count > 0) ? lines[0].score : 0;

        int myColor = gMyColor;
        NSMutableArray *extras = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            if (i == pick) continue;
            NSString *mv = [NSString stringWithUTF8String:lines[i].move];
            double evWhite = 0; BOOL cm = NO; int cMate = 0;
            if (lines[i].hasScore) {
                if (lines[i].isMate) { cm = YES; cMate = stmWhite ? lines[i].score : -lines[i].score; }
                else { double cp = lines[i].score / 100.0; evWhite = stmWhite ? cp : -cp; }
            }
            double evUs = (myColor == 1) ? -evWhite : evWhite;
            int mateUs  = (myColor == 1) ? -cMate : cMate;
            [extras addObject:@{@"move": mv, @"label": formatEvalLabel(evUs, cm, mateUs)}];
        }

        double secondWhite = 0; BOOL have2nd = NO;
        if (count >= 2 && lines[1].hasScore && !lines[1].isMate) {
            double cp = lines[1].score / 100.0;
            secondWhite = stmWhite ? cp : -cp;
            have2nd = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            gFetching = NO;
            if (gPendingFen && ![gPendingFen isEqualToString:gLastFen]) {
                NSString *next = [gPendingFen copy];
                gPendingFen = nil;
                dispatch_async(dispatch_get_main_queue(), ^{ fetchMove(next); });
            } else {
                gPendingFen = nil;
            }
            if (![snap isEqualToString:gLastFen]) { dbg(@"stale resp"); return; }
            if (!bm.length || [bm isEqualToString:@"(none)"]) {
                dbg(@"no bestmove"); return;
            }

            double rawWhite = 0; int mateIn = 0; BOOL mate = NO;
            if (hasScore) {
                if (lmate) { mate = YES; mateIn = stmWhite ? lscore : -lscore; }
                else { double cp = lscore / 100.0; rawWhite = stmWhite ? cp : -cp; }
            }
            applyEngineResult(bm, extras, mate, mateIn, rawWhite, drawBoard);
            if (gTrackQuality) noteUserEval(snap, mate ? 0 : rawWhite, !mate && hasScore, secondWhite, have2nd);
        });
    });
}

static __weak id gEngineCtrl = nil;
static __weak id gHookedEngine = nil;
static NSString *gLastEngineFEN = nil;

typedef struct { uint64_t w0; uint64_t w1; } RawSwiftString;

typedef RawSwiftString (*SwiftGetFenFunc)(void *self);
static SwiftGetFenFunc gOrigSwiftGetFen = NULL;

typedef NSString *(*SwiftStringBridgeFunc)(uint64_t w0, uint64_t w1);
static SwiftStringBridgeFunc gSwiftStringBridge = NULL;

static NSString *gSwiftFEN = nil;
static BOOL gSwiftHookActive = NO;

static RawSwiftString hook_swiftGetFen(void *self) {
    RawSwiftString result = gOrigSwiftGetFen(self);
    if (gSwiftStringBridge && gEnabled) {
        @autoreleasepool {
            @try {
                NSString *ns = gSwiftStringBridge(result.w0, result.w1);
                if ([ns isKindOfClass:[NSString class]] && ns.length > 10
                    && [ns containsString:@"/"]) {
                    gSwiftFEN = [ns copy];
                }
            } @catch (NSException *e) {}
        }
    }
    return result;
}

typedef RawSwiftString (*SwiftGetTcnFunc)(void *self);
static SwiftGetTcnFunc gOrigSwiftGetTcn = NULL;
static NSString *gSwiftTCN = nil;

static RawSwiftString hook_swiftGetTcn(void *self) {
    RawSwiftString result = gOrigSwiftGetTcn(self);
    if (gSwiftStringBridge && gEnabled) {
        @autoreleasepool {
            @try {
                NSString *ns = gSwiftStringBridge(result.w0, result.w1);
                if ([ns isKindOfClass:[NSString class]] && ns.length > 0) {
                    gSwiftTCN = [ns copy];
                }
            } @catch (NSException *e) {}
        }
    }
    return result;
}

static id searchVCForEngine(UIViewController *vc, int depth) {
    if (!vc || depth > 10) return nil;
    typedef id (*IdGetter)(id, SEL);
    IdGetter getObj = (IdGetter)objc_msgSend;
    SEL fenSel = NSSelectorFromString(@"getCurrentFen");

    NSArray *props = @[@"gameController", @"chessGameController", @"engineController",
                       @"interactor", @"viewModel", @"presenter", @"boardOwner",
                       @"game", @"chessGame", @"activeGame", @"currentGame",
                       @"delegate", @"coordinator"];
    for (NSString *prop in props) {
        SEL sel = NSSelectorFromString(prop);
        if (![vc respondsToSelector:sel]) continue;
        @try {
            id val = getObj(vc, sel);
            if (!val) continue;
            if ([val respondsToSelector:fenSel]) return val;

            for (NSString *sub in props) {
                SEL subSel = NSSelectorFromString(sub);
                if ([val respondsToSelector:subSel]) {
                    @try {
                        id sv = getObj(val, subSel);
                        if (sv && [sv respondsToSelector:fenSel]) return sv;
                    } @catch (NSException *e) {}
                }
            }
        } @catch (NSException *e) {}
    }

    for (UIViewController *child in vc.childViewControllers) {
        id found = searchVCForEngine(child, depth + 1);
        if (found) return found;
    }
    if (vc.presentedViewController) {
        id found = searchVCForEngine(vc.presentedViewController, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIView *findBoardArea(UIView *view, int depth) {
    if (!view || depth > 25) return nil;
    CGFloat w = view.bounds.size.width, h = view.bounds.size.height;

    if (w > 200 && h > 200 && fabs(w - h) < w * 0.15
        && !view.hidden && view.alpha > 0.1
        && h < [UIScreen mainScreen].bounds.size.height * 0.8) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = findBoardArea(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static BOOL processBotBoard(UIView *board);

static id findOnlineGame(UIView *board) {
    if (!board) return nil;
    SEL encSel = NSSelectorFromString(@"encodedMoves");
    NSArray *sels = @[@"game", @"chessGame", @"currentGame", @"gameModel",
                      @"boardModel", @"chessBoardModel", @"viewModel", @"activeGame"];
    UIResponder *r = board;
    for (int d = 0; d < 16 && r; d++) {
        for (NSString *s in sels) {
            SEL sel = NSSelectorFromString(s);
            if ([r respondsToSelector:sel]) {
                @try {
                    id g = ((id (*)(id, SEL))objc_msgSend)(r, sel);
                    if (g && [g respondsToSelector:encSel]) return g;
                } @catch (NSException *e) {}
            }
        }
        r = [r nextResponder];
    }
    return nil;
}

static BOOL drivePuzzle(UIView *board);

static void enginePollTick(void) {
    if (!gEnabled) return;

    if (gHasEval &&
        !(gBotBoard  && isBoardOnScreen(gBotBoard)) &&
        !(gDrawBoard && isBoardOnScreen(gDrawBoard))) {
        clearArrow();
        removeEvalBar();
        updateFloatBtn(@"♟");
        gHasEval = NO;
        gBarHave = NO;
        gLastFen = nil;
        resetAccuracy();
    }

    if (gPuzzleBoard && isBoardOnScreen(gPuzzleBoard)) {
        if (drivePuzzle(gPuzzleBoard)) return;
    }

    BOOL botMoreRecent = gBotSeen && (!gOnlineSeen ||
        [gBotSeen compare:gOnlineSeen] == NSOrderedDescending);

    if (botMoreRecent) {
        if (processBotBoard(gBotBoard)) return;

    }

    if (!gOnlineGame) gOnlineGame = findOnlineGame(gBoardView);
    if (gOnlineGame) {
        if (gOnlineDrawBoard) gDrawBoard = gOnlineDrawBoard;
        reassertArrow(gDrawBoard);
        updateEvalBar();
        @try {
            typedef NSString *(*SG)(id, SEL);
            SEL encSel = NSSelectorFromString(@"encodedMoves");
            if ([gOnlineGame respondsToSelector:encSel]) {
                NSString *encoded = ((SG)objc_msgSend)(gOnlineGame, encSel);
                SEL iSel = NSSelectorFromString(@"initialFEN");
                NSString *iFen = [gOnlineGame respondsToSelector:iSel]
                                  ? ((SG)objc_msgSend)(gOnlineGame, iSel) : nil;
                if (!iFen.length) iFen = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
                NSString *fen = decodeTCNToFEN(iFen, encoded ?: @"");
                if (fen.length) {
                    parseFEN(fen);
                    if (!(gMyColor >= 0 && gMyColor != gSide)) {
                        gForcedFlip = -1;
                        fetchMove(fen);
                    } else {
                        clearArrow();
                        analyzeUserMove(fen);
                        MaiaNotePly([fen UTF8String]);
                    }
                }
            }
        } @catch (NSException *e) {}
        return;
    }

    if (gSwiftHookActive) {
        NSString *sfn = gSwiftFEN;
        if (sfn.length > 10 && [sfn containsString:@"/"]) {
            if ([sfn isEqualToString:gLastEngineFEN]) return;
            gLastEngineFEN = [sfn copy];
            parseFEN(sfn);

            if (gMyColor >= 0 && gMyColor != gSide) { analyzeUserMove(sfn); MaiaNotePly([sfn UTF8String]); return; }

            dbg([NSString stringWithFormat:@"SWIFT FEN: %@",
                 [sfn substringToIndex:MIN(sfn.length, 55)]]);

            if (!gBoardView || ![(UIView *)gBoardView window]) {
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    if (win == gBtnWin || win == gMenuWin) continue;
                    UIView *board = findBoardArea(win, 0);
                    if (board) { gBoardView = board; break; }
                }
            }
            fetchMove(sfn);
            return;
        }

        NSString *tcn = gSwiftTCN;
        if (tcn.length > 0) {
            NSString *startFEN = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
            NSString *decoded = decodeTCNToFEN(startFEN, tcn);
            if (decoded.length > 10 && [decoded containsString:@"/"]) {
                if ([decoded isEqualToString:gLastEngineFEN]) return;
                gLastEngineFEN = [decoded copy];
                parseFEN(decoded);

                if (gMyColor >= 0 && gMyColor != gSide) { analyzeUserMove(decoded); MaiaNotePly([decoded UTF8String]); return; }

                dbg([NSString stringWithFormat:@"SWIFT TCN→FEN: %@",
                     [decoded substringToIndex:MIN(decoded.length, 55)]]);

                if (!gBoardView || ![(UIView *)gBoardView window]) {
                    for (UIWindow *win in [UIApplication sharedApplication].windows) {
                        if (win == gBtnWin || win == gMenuWin) continue;
                        UIView *board = findBoardArea(win, 0);
                        if (board) { gBoardView = board; break; }
                    }
                }
                fetchMove(decoded);
                return;
            }
        }

        return;
    }

    if (!gEngineCtrl && gHookedEngine) {
        gEngineCtrl = gHookedEngine;
        dbg([NSString stringWithFormat:@"ENGINE: via hook %@",
             NSStringFromClass([gHookedEngine class])]);
        dumpMoveSelectors(gHookedEngine, @"engine");
    }

    if (!gEngineCtrl) {
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            UIViewController *root = win.rootViewController;
            if (!root) continue;
            id found = searchVCForEngine(root, 0);
            if (found) {
                gEngineCtrl = found;
                dbg([NSString stringWithFormat:@"ENGINE: found %@",
                     NSStringFromClass([found class])]);
                dumpMoveSelectors(found, @"engine");
                break;
            }
        }
        if (!gEngineCtrl) return;
    }

    NSArray *fenSelNames = @[@"getCurrentFen", @"getMainLineTcnString",
                              @"currentFen", @"fen", @"positionFen"];
    NSString *fen = nil;

    for (NSString *selName in fenSelNames) {
        SEL sel = NSSelectorFromString(selName);

        if ([gEngineCtrl respondsToSelector:sel]) {
            @try {
                typedef NSString *(*StrGetter)(id, SEL);
                NSString *result = ((StrGetter)objc_msgSend)(gEngineCtrl, sel);
                if ([result isKindOfClass:[NSString class]] && result.length > 10
                    && [result containsString:@"/"]) {
                    fen = result;
                    static NSString *sLoggedSel = nil;
                    if (![selName isEqualToString:sLoggedSel]) {
                        sLoggedSel = selName;
                        dbg([NSString stringWithFormat:@"ENGINE FEN via %@", selName]);
                    }
                    break;
                }
            } @catch (NSException *e) {}
        }
    }

    if (!fen) {
        @try {
            typedef NSString *(*StrGetter)(id, SEL);
            SEL fenSel = NSSelectorFromString(@"getCurrentFen");
            NSString *result = ((StrGetter)objc_msgSend)(gEngineCtrl, fenSel);
            if ([result isKindOfClass:[NSString class]] && result.length > 10
                && [result containsString:@"/"]) {
                fen = result;
                static BOOL sLoggedBrute = NO;
                if (!sLoggedBrute) { sLoggedBrute = YES; dbg(@"ENGINE FEN via brute getCurrentFen"); }
            }
        } @catch (NSException *e) {

            static BOOL sLoggedFail = NO;
            if (!sLoggedFail) {
                sLoggedFail = YES;
                dbg([NSString stringWithFormat:@"ENGINE no FEN method works: %@", e.reason]);
            }
            gEngineCtrl = nil;
            return;
        }
    }

    if (!fen) return;
    if ([fen isEqualToString:gLastEngineFEN]) return;
    gLastEngineFEN = [fen copy];
    parseFEN(fen);

    if (gMyColor >= 0 && gMyColor != gSide) return;

    dbg([NSString stringWithFormat:@"ENGINE FEN: %@",
         [fen substringToIndex:MIN(fen.length, 55)]]);

    if (!gBoardView || ![(UIView *)gBoardView window]) {
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            if (win == gBtnWin || win == gMenuWin) continue;
            UIView *board = findBoardArea(win, 0);
            if (board) { gBoardView = board; break; }
        }
    }

    gForcedFlip = -1;
    gDrawBoard = gBoardView;
    fetchMove(fen);
}

typedef void (*OrigLayout)(id, SEL);
static NSMutableDictionary *gOrigLayouts = nil;
static NSString *gLastEncoded = nil;
static NSDate   *gLastLayoutCheck = nil;

static NSMutableSet *gClassPtrSet = nil;
static void buildClassPtrSet(void) {
    gClassPtrSet = [NSMutableSet set];
    unsigned int n = 0;
    Class *cl = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++)
        [gClassPtrSet addObject:[NSValue valueWithPointer:(__bridge const void *)cl[i]]];
    if (cl) free(cl);
}
static NSString *safeClassName(const void *p) {
    if (!p) return nil;
    if (((uintptr_t)p & 0x7) != 0) return nil;
    if (malloc_size(p) == 0) return nil;
    Class c = object_getClass((__bridge id)p);
    if (!c) return nil;
    if (!gClassPtrSet) buildClassPtrSet();
    if (![gClassPtrSet containsObject:[NSValue valueWithPointer:(__bridge const void *)c]])
        return nil;
    return NSStringFromClass(c);
}

static NSString *gLastBotPlacement = nil;
static int       gBotSide = 0;
static char      gPrevBotBoard[8][8];
static BOOL      gHavePrevBoard = NO;

static NSString *buildBotFEN(UIView *board, int *outUserColor) {
    const uint8_t *base = (const uint8_t *)(__bridge const void *)board;

    Ivar dragIv = class_getInstanceVariable([board class], "pieceDragView");
    if (dragIv) {
        void *dp = *(void *const *)(base + ivar_getOffset(dragIv));
        if (safeClassName(dp) && ((__bridge UIView *)dp).subviews.count > 0) return nil;
    }

    Ivar povIv = class_getInstanceVariable([board class], "piecesOverlayView");
    ptrdiff_t povOff = povIv ? ivar_getOffset(povIv) : 408;
    void *povPtr = *(void *const *)(base + povOff);
    if (!safeClassName(povPtr)) return nil;
    UIView *overlay = (__bridge UIView *)povPtr;

    CGFloat sq = board.bounds.size.width / 8.0;
    if (sq <= 0) return nil;

    const char *LETTERS = "PNBRQK";

    NSArray<UIView *> *snapshot = [overlay.subviews copy];

    uint8_t pcColor[64], pcType[64]; int pcCol[64], pcRow[64], pcN = 0;
    for (UIView *pv in snapshot) {
        if (![NSStringFromClass([pv class]) containsString:@"PieceView"]) continue;

        const void *pvp = (__bridge const void *)pv;
        if (malloc_size(pvp) == 0) continue;
        if (pv.layer.animationKeys.count > 0) return nil;
        if (pv.hidden || pv.alpha < 0.5) return nil;

        const uint8_t *pb = (const uint8_t *)pvp;
        Ivar pieceIv = class_getInstanceVariable([pv class], "piece");
        ptrdiff_t pieceOff = pieceIv ? ivar_getOffset(pieceIv) : 512;
        uint8_t color = *(pb + pieceOff + 0);
        uint8_t type  = *(pb + pieceOff + 16);
        if (color < 1 || color > 2 || type < 1 || type > 6) continue;

        Ivar ghostIv = class_getInstanceVariable([pv class], "isGhost");
        if (ghostIv && *(pb + ivar_getOffset(ghostIv))) return nil;

        CGRect f = [pv convertRect:pv.bounds toView:board];
        CGFloat cx = CGRectGetMidX(f), cy = CGRectGetMidY(f);
        int scol = (int)(cx / sq);
        int srow = (int)(cy / sq);
        if (scol < 0 || scol > 7 || srow < 0 || srow > 7) continue;
        if (fabs(cx - (scol * sq + sq / 2)) > sq * 0.35 ||
            fabs(cy - (srow * sq + sq / 2)) > sq * 0.35) return nil;

        if (pcN < 64) {
            pcColor[pcN] = color; pcType[pcN] = type;
            pcCol[pcN] = scol;    pcRow[pcN] = srow;   pcN++;
        }
    }
    if (pcN < 2) return nil;

    double wSum = 0, bSum = 0; int wN = 0, bN = 0;
    for (int i = 0; i < pcN; i++) {
        if (pcColor[i] == 1) { wSum += pcRow[i]; wN++; }
        else                 { bSum += pcRow[i]; bN++; }
    }
    double wAvg = wN ? wSum / wN : 0.0;
    double bAvg = bN ? bSum / bN : 7.0;
    BOOL flipped = (wAvg < bAvg);
    Ivar flipIv = class_getInstanceVariable([board class], "isFlipped");
    if (flipIv) {
        const uint8_t *bb = (const uint8_t *)(__bridge const void *)board;
        flipped = (*(bb + ivar_getOffset(flipIv)) & 1) ? YES : NO;
    }

    char bd[8][8];
    memset(bd, 0, sizeof(bd));
    for (int i = 0; i < pcN; i++) {
        int rankIdx, file;
        if (!flipped) { rankIdx = 7 - pcRow[i]; file = pcCol[i]; }
        else          { rankIdx = pcRow[i];     file = 7 - pcCol[i]; }
        if (rankIdx < 0 || rankIdx > 7 || file < 0 || file > 7) continue;
        char ch = LETTERS[pcType[i] - 1];
        if (pcColor[i] == 2) ch = (char)(ch + 32);
        bd[rankIdx][file] = ch;
    }

    int wpN = 0, bpN = 0;
    double wpSum = 0, bpSum = 0;
    BOOL illegal = NO;
    for (int r = 0; r < 8; r++) {
        for (int f = 0; f < 8; f++) {
            char ch = bd[r][f];
            if (ch == 'P') { wpSum += r; wpN++; if (r == 0) illegal = YES; }
            else if (ch == 'p') { bpSum += r; bpN++; if (r == 7) illegal = YES; }
        }
    }
    BOOL statInverted = (wpN >= 4 && bpN >= 4 && (wpSum / wpN) - (bpSum / bpN) > 2.0);
    if (illegal || statInverted) {
        char rot[8][8];
        for (int r = 0; r < 8; r++)
            for (int f = 0; f < 8; f++) rot[r][f] = bd[7 - r][7 - f];
        memcpy(bd, rot, sizeof(bd));
        flipped = !flipped;
        static int sLastCorrected = -1;
        if (sLastCorrected != (flipped ? 1 : 0)) {
            sLastCorrected = flipped ? 1 : 0;
            dbg([NSString stringWithFormat:@"orientation corrected -> flipped=%d", flipped]);
        }
    }

    gForcedFlip = flipped ? 1 : 0;

    NSMutableString *pl = [NSMutableString string];
    for (int r = 7; r >= 0; r--) {
        int empty = 0;
        for (int file = 0; file < 8; file++) {
            char ch = bd[r][file];
            if (!ch) { empty++; }
            else {
                if (empty) { [pl appendFormat:@"%d", empty]; empty = 0; }
                [pl appendFormat:@"%c", ch];
            }
        }
        if (empty) [pl appendFormat:@"%d", empty];
        if (r > 0) [pl appendString:@"/"];
    }

    if (gPuzzleCtx) gBotSide = flipped ? 1 : 0;

    NSString *startpos = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR";
    if (![pl isEqualToString:gLastBotPlacement]) {
        if (gPuzzleCtx) {
        } else if ([pl isEqualToString:startpos]) {
            gBotSide = 0;
            if (gAccCount > 0) resetAccuracy();
            [gUciSeq setString:@""];
        } else if (gHavePrevBoard) {

            int whiteMoved = 0, blackMoved = 0;
            for (int r = 0; r < 8; r++) {
                for (int f = 0; f < 8; f++) {
                    char now = bd[r][f];
                    if (now != 0 && now != gPrevBotBoard[r][f]) {
                        if (now >= 'A' && now <= 'Z') whiteMoved++;
                        else                          blackMoved++;
                    }
                }
            }

            if (whiteMoved == 0 && blackMoved == 0) return nil;

            if (whiteMoved > 0 && blackMoved == 0)      gBotSide = 1;
            else if (blackMoved > 0 && whiteMoved == 0) gBotSide = 0;

        } else {
            gBotSide = flipped ? 1 : 0;
        }
        memcpy(gPrevBotBoard, bd, sizeof(bd));
        gHavePrevBoard = YES;
        gLastBotPlacement = [pl copy];
    }

    NSMutableString *cas = [NSMutableString string];
    if (bd[0][4] == 'K' && bd[0][7] == 'R') [cas appendString:@"K"];
    if (bd[0][4] == 'K' && bd[0][0] == 'R') [cas appendString:@"Q"];
    if (bd[7][4] == 'k' && bd[7][7] == 'r') [cas appendString:@"k"];
    if (bd[7][4] == 'k' && bd[7][0] == 'r') [cas appendString:@"q"];
    if (cas.length == 0) [cas setString:@"-"];

    if (outUserColor) *outUserColor = flipped ? 1 : 0;

    return [NSString stringWithFormat:@"%@ %@ %@ - 0 1",
            pl, gBotSide ? @"b" : @"w", cas];
}

static BOOL processBotBoard(UIView *board) {
    if (!board || !board.window) return NO;

    if (![NSStringFromClass([board class]) isEqualToString:@"SwiftChessBoard.ChessBoard"])
        return NO;
    if (!isBoardOnScreen(board)) return NO;
    gBotBoard = board;
    dumpMoveSelectors(board, @"board");

    BOOL inBotGame = NO;
    gPuzzleCtx = NO;
    UIResponder *pr = board;
    for (int pd = 0; pd < 14 && pr; pd++) {
        NSString *cn = NSStringFromClass([pr class]);
        if ([cn containsString:@"Puzzle"] || [cn containsString:@"Tactics"]) {
            inBotGame = YES; gPuzzleCtx = YES; break;
        }
        if ([cn containsString:@"PlayBot"] || [cn containsString:@"Coach"] ||
            [cn containsString:@"Lesson"]) { inBotGame = YES; break; }
        pr = [pr nextResponder];
    }
    if (!inBotGame) return NO;

    gOnlineGame = nil;
    gBoardView = board;
    gDrawBoard = board;
    int userColor = 0;
    NSString *fen = buildBotFEN(board, &userColor);
    if (!fen) return YES;

    setMyColor(userColor, @"processBotBoard");
    static NSString *sLastBotFen = nil;
    if (![fen isEqualToString:sLastBotFen]) {
        sLastBotFen = [fen copy];
        dbg([NSString stringWithFormat:@"BOT FEN: %@", fen]);
    }
    if (gBotSide == userColor) {
        fetchMove(fen);
    } else {
        clearArrow();
        analyzeUserMove(fen);
        MaiaNotePly([fen UTF8String]);
    }
    return YES;
}

static UIView *resolveDrawBoard(UIView *v) {
    UIView *cur = v;
    for (int i = 0; cur && i < 12; i++) {
        if ([NSStringFromClass([cur class]) isEqualToString:@"SwiftChessBoard.ChessBoard"])
            return cur;
        cur = cur.superview;
    }
    return v;
}

static NSString *buildPuzzleFENFromLabels(UIView *board) {
    if (!board || !board.window) return nil;
    CGRect boardRect = [board convertRect:board.bounds toView:nil];
    if (boardRect.size.width < 40) return nil;

    int flipped = -1;
    @try {
        SEL fs = NSSelectorFromString(@"isFlipped");
        if ([board respondsToSelector:fs]) flipped = ((BOOL (*)(id, SEL))objc_msgSend)(board, fs) ? 1 : 0;
    } @catch (NSException *e) {}

    char bd[8][8];
    memset(bd, 0, sizeof(bd));
    int count = 0;
    double wY = 0, bY = 0;
    int wN = 0, bN = 0;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:board.window];
    int visited = 0;
    while (stack.count && visited < 5000) {
        UIView *vw = [stack lastObject];
        [stack removeLastObject];
        visited++;
        for (UIView *sub in vw.subviews) [stack addObject:sub];

        NSString *al = nil;
        @try { al = vw.accessibilityLabel; } @catch (NSException *e) {}
        if (al.length < 7) continue;
        BOOL white;
        if ([al hasPrefix:@"White "]) white = YES;
        else if ([al hasPrefix:@"Black "]) white = NO;
        else continue;

        NSString *rest = [al substringFromIndex:6];
        if (rest.length < 3) continue;
        NSString *sq = [rest substringFromIndex:rest.length - 2];
        NSString *pieceName = [rest substringToIndex:rest.length - 2];
        unichar ff = [sq characterAtIndex:0], rr = [sq characterAtIndex:1];
        if (ff < 'a' || ff > 'h' || rr < '1' || rr > '8') continue;

        CGRect wf = [vw convertRect:vw.bounds toView:nil];
        if (!CGRectContainsPoint(boardRect, CGPointMake(CGRectGetMidX(wf), CGRectGetMidY(wf)))) continue;

        char pc = 0;
        if ([pieceName isEqualToString:@"Pawn"])   pc = 'P';
        else if ([pieceName isEqualToString:@"Knight"]) pc = 'N';
        else if ([pieceName isEqualToString:@"Bishop"]) pc = 'B';
        else if ([pieceName isEqualToString:@"Rook"])   pc = 'R';
        else if ([pieceName isEqualToString:@"Queen"])  pc = 'Q';
        else if ([pieceName isEqualToString:@"King"])   pc = 'K';
        else continue;
        if (!white) pc = (char)tolower(pc);

        int file = ff - 'a', rank = rr - '1';
        bd[rank][file] = pc;
        count++;
        if (white) { wY += CGRectGetMidY(wf); wN++; }
        else       { bY += CGRectGetMidY(wf); bN++; }
    }
    if (count < 2 || count > 32) return nil;

    int wk = 0, bk = 0;
    for (int r = 0; r < 8; r++)
        for (int f = 0; f < 8; f++) {
            if (bd[r][f] == 'K') wk++;
            else if (bd[r][f] == 'k') bk++;
        }
    if (wk != 1 || bk != 1) return nil;

    NSMutableString *pl = [NSMutableString string];
    for (int r = 7; r >= 0; r--) {
        int e = 0;
        for (int f = 0; f < 8; f++) {
            char c = bd[r][f];
            if (!c) { e++; }
            else { if (e) { [pl appendFormat:@"%d", e]; e = 0; } [pl appendFormat:@"%c", c]; }
        }
        if (e) [pl appendFormat:@"%d", e];
        if (r > 0) [pl appendString:@"/"];
    }

    NSMutableString *cas = [NSMutableString string];
    if (bd[0][4] == 'K' && bd[0][7] == 'R') [cas appendString:@"K"];
    if (bd[0][4] == 'K' && bd[0][0] == 'R') [cas appendString:@"Q"];
    if (bd[7][4] == 'k' && bd[7][7] == 'r') [cas appendString:@"k"];
    if (bd[7][4] == 'k' && bd[7][0] == 'r') [cas appendString:@"q"];
    if (!cas.length) [cas setString:@"-"];

    NSString *fenW = [NSString stringWithFormat:@"%@ w %@ - 0 1", pl, cas];
    NSString *fenB = [NSString stringWithFormat:@"%@ b %@ - 0 1", pl, cas];

    if (flipped == 1) return StockfishFenLegal([fenB UTF8String]) ? fenB : nil;
    if (flipped == 0) return StockfishFenLegal([fenW UTF8String]) ? fenW : nil;

    BOOL okW = StockfishFenLegal([fenW UTF8String]);
    BOOL okB = StockfishFenLegal([fenB UTF8String]);
    if (okW && !okB) return fenW;
    if (okB && !okW) return fenB;
    if (!okW && !okB) return nil;
    double wAvg = wN ? wY / wN : 0, bAvg = bN ? bY / bN : 0;
    return (bN && wN && bAvg > wAvg) ? fenB : fenW;
}

static BOOL drivePuzzle(UIView *board) {
    NSString *pf = buildPuzzleFENFromLabels(board);
    if (!pf.length) return NO;
    parseFEN(pf);
    setMyColor(gSide, @"drivePuzzle");
    static NSString *sLastPuzzleFen = nil;
    if (![pf isEqualToString:sLastPuzzleFen]) {
        sLastPuzzleFen = [pf copy];
        dbg([NSString stringWithFormat:@"PUZZLE FEN: %@", pf]);
    }
    gForcedFlip = -1;
    gDrawBoard = board;
    fetchMove(pf);
    return YES;
}

static void hook_layoutSubviews(id self, SEL _cmd) {

    Class c = [self class];
    while (c) {
        NSValue *origVal = gOrigLayouts[NSStringFromClass(c)];
        if (origVal) {
            OrigLayout orig = NULL;
            [origVal getValue:&orig];
            if (orig) orig(self, _cmd);
            break;
        }
        c = class_getSuperclass(c);
    }
    if (!gEnabled) return;

    UIView *boardSelf = (UIView *)self;
    if (!boardSelf.window) return;
    if (CGRectIsEmpty(boardSelf.bounds)) return;

    if (!isBoardOnScreen(boardSelf)) return;

    gBoardView = boardSelf;

    reassertArrow(gDrawBoard);
    updateEvalBar();

    NSDate *now = [NSDate date];
    if (gLastLayoutCheck && [now timeIntervalSinceDate:gLastLayoutCheck] < 0.5) return;
    gLastLayoutCheck = now;

    if (processBotBoard(boardSelf)) gBotSeen = [NSDate date];

    @try {
        typedef id (*IdGetter)(id, SEL);
        IdGetter getObj = (IdGetter)objc_msgSend;
        typedef NSString *(*StrGetter)(id, SEL);
        StrGetter strGet = (StrGetter)objc_msgSend;
        typedef NSInteger (*IntGetter)(id, SEL);
        IntGetter getInt = (IntGetter)objc_msgSend;

        static NSInteger gLastRawColor = -99;
        SEL colorSel = NSSelectorFromString(@"myPieceColor");
        if ([self respondsToSelector:colorSel]) {

            gOnlineDrawBoard = boardSelf;
            NSInteger raw = getInt(self, colorSel);
            if (raw != gLastRawColor) {
                gLastRawColor = raw;
                dbg([NSString stringWithFormat:@"myPieceColor raw=%ld", (long)raw]);
            }

            if (raw == 1) setMyColor(0, [NSString stringWithFormat:@"myPieceColor raw=1 %@", NSStringFromClass([self class])]);
            else if (raw == 2) setMyColor(1, [NSString stringWithFormat:@"myPieceColor raw=2 %@", NSStringFromClass([self class])]);
            else if (raw == 0) {

                SEL flipSel = NSSelectorFromString(@"isFlipped");
                if ([self respondsToSelector:flipSel]) {
                    typedef BOOL (*BoolGetter)(id, SEL);
                    BOOL flipped = ((BoolGetter)objc_msgSend)(self, flipSel);
                    setMyColor(flipped ? 1 : 0, [NSString stringWithFormat:@"raw=0 isFlipped=%d %@", flipped, NSStringFromClass([self class])]);
                }
            }
        } else {

            SEL flipSel2 = NSSelectorFromString(@"isFlipped");
            if ([self respondsToSelector:flipSel2]) {
                typedef BOOL (*BoolGetter)(id, SEL);
                BOOL flipped = ((BoolGetter)objc_msgSend)(self, flipSel2);
                NSInteger newColor = flipped ? 1 : 0;
                if (newColor != gMyColor) {
                    setMyColor(newColor, [NSString stringWithFormat:@"isFlipped-only %@", NSStringFromClass([self class])]);
                    dbg([NSString stringWithFormat:@"color via isFlipped: %@",
                         flipped ? @"black" : @"white"]);
                }
            } else {
                static BOOL gLoggedNoColor = NO;
                if (!gLoggedNoColor) {
                    gLoggedNoColor = YES;
                    dbg(@"WARN: board has no myPieceColor or isFlipped");
                }
            }
        }

        NSArray *gameSelNames = @[@"game", @"chessGame", @"puzzle", @"currentGame",
                                  @"gameModel", @"chessBoardModel", @"boardModel",
                                  @"viewModel", @"botGame", @"playGame", @"activeGame",
                                  @"coachGame", @"lessonGame", @"practiceGame"];
        UIResponder *resp = [(UIView *)self nextResponder];
        id game = nil;
        int chainDepth = 0;
        static NSString *gLoggedChainVC = nil;
        NSMutableString *chainLog = [NSMutableString string];

        while (resp && chainDepth < 20) {
            [chainLog appendFormat:@"%@→", NSStringFromClass([resp class])];
            for (NSString *selName in gameSelNames) {
                SEL sel = NSSelectorFromString(selName);
                if ([resp respondsToSelector:sel]) {
                    @try {
                        id obj = getObj(resp, sel);
                        if (obj) {
                            game = obj;
                            NSString *vcName = NSStringFromClass([resp class]);
                            if (![vcName isEqualToString:gLoggedChainVC]) {
                                gLoggedChainVC = vcName;
                                dbg([NSString stringWithFormat:@"game via .%@ on %@ (class: %@)",
                                     selName, vcName, NSStringFromClass([obj class])]);
                            }
                            break;
                        }
                    } @catch (NSException *e) {}
                }
            }
            if (game) break;
            resp = [resp nextResponder];
            chainDepth++;
        }

        NSString *currentFEN = nil;

        if (game) {
            SEL encSel = NSSelectorFromString(@"encodedMoves");
            if ([game respondsToSelector:encSel]) {
                gOnlineGame = game;
                dumpMoveSelectors(game, @"game");
                gOnlineSeen = [NSDate date];
                gBotBoard = nil;
                NSString *encoded = strGet(game, encSel);
                NSString *encKey = encoded.length ? encoded : @"__EMPTY__";
                if ([encKey isEqualToString:gLastEncoded]) return;
                gLastEncoded = [encKey copy];

                SEL iFenSel = NSSelectorFromString(@"initialFEN");
                NSString *initialFEN = nil;
                if ([game respondsToSelector:iFenSel]) initialFEN = strGet(game, iFenSel);
                if (!initialFEN.length) initialFEN = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
                currentFEN = decodeTCNToFEN(initialFEN, encoded);
            }
        }

        if (!currentFEN && gHookedEngine) {
            SEL hFenSel = NSSelectorFromString(@"getCurrentFen");
            if ([gHookedEngine respondsToSelector:hFenSel]) {
                @try {
                    typedef NSString *(*StrGetter2)(id, SEL);
                    NSString *hfen = ((StrGetter2)objc_msgSend)(gHookedEngine, hFenSel);
                    if (hfen.length > 10 && [hfen containsString:@"/"]) {
                        if ([hfen isEqualToString:gLastEncoded]) return;
                        gLastEncoded = [hfen copy];
                        parseFEN(hfen);
                        currentFEN = hfen;
                        static BOOL gLoggedHk = NO;
                        if (!gLoggedHk) {
                            gLoggedHk = YES;
                            dbg([NSString stringWithFormat:@"FEN via hooked %@",
                                 NSStringFromClass([gHookedEngine class])]);
                        }
                    }
                } @catch (NSException *e) {}
            }
        }

        if (!currentFEN) {

            NSMutableArray *probeTargets = [NSMutableArray array];

            NSArray *linkProps = @[@"delegate", @"dataSource", @"boardOwner", @"owner",
                                    @"coordinator", @"interactor", @"presenter"];
            for (NSString *lp in linkProps) {
                SEL lpSel = NSSelectorFromString(lp);
                if ([self respondsToSelector:lpSel]) {
                    @try {
                        id linked = getObj(self, lpSel);
                        if (linked) [probeTargets addObject:linked];
                    } @catch (NSException *e) {}
                }
            }

            UIResponder *r2 = [(UIView *)self nextResponder];
            int d2 = 0;
            while (r2 && d2 < 15) {
                [probeTargets addObject:r2];
                r2 = [r2 nextResponder];
                d2++;
            }

            SEL fenSel = NSSelectorFromString(@"getCurrentFen");
            NSArray *controllerProps = @[@"gameController", @"chessGameController",
                                         @"engineController", @"interactor", @"boardOwner"];

            for (id target in probeTargets) {

                if ([target respondsToSelector:fenSel]) {
                    @try {
                        NSString *fen = strGet(target, fenSel);
                        if (fen.length > 10 && [fen containsString:@"/"]) {
                            if ([fen isEqualToString:gLastEncoded]) return;
                            gLastEncoded = [fen copy];
                            parseFEN(fen);
                            currentFEN = fen;
                            static BOOL gLoggedEngine = NO;
                            if (!gLoggedEngine) {
                                gLoggedEngine = YES;
                                dbg([NSString stringWithFormat:@"FEN via getCurrentFen on %@",
                                     NSStringFromClass([target class])]);
                            }
                            break;
                        }
                    } @catch (NSException *e) {}
                }

                for (NSString *cp in controllerProps) {
                    SEL cpSel = NSSelectorFromString(cp);
                    if (![target respondsToSelector:cpSel]) continue;
                    @try {
                        id controller = getObj(target, cpSel);
                        if (!controller) continue;

                        if ([controller respondsToSelector:fenSel]) {
                            NSString *fen = strGet(controller, fenSel);
                            if (fen.length > 10 && [fen containsString:@"/"]) {
                                if ([fen isEqualToString:gLastEncoded]) return;
                                gLastEncoded = [fen copy];
                                parseFEN(fen);
                                currentFEN = fen;
                                static BOOL gLoggedCtrl = NO;
                                if (!gLoggedCtrl) {
                                    gLoggedCtrl = YES;
                                    dbg([NSString stringWithFormat:@"FEN via .%@.getCurrentFen on %@",
                                         cp, NSStringFromClass([target class])]);
                                }
                            }
                        }

                        if (!currentFEN) {
                            SEL encSel2 = NSSelectorFromString(@"encodedMoves");
                            if ([controller respondsToSelector:encSel2]) {
                                if (!game) game = controller;
                            }
                        }
                    } @catch (NSException *e) {}
                    if (currentFEN) break;
                }
                if (currentFEN) break;
            }
        }

        if (!currentFEN) {
            NSArray *fenSelNames = @[@"fen", @"currentFEN", @"fenString", @"position",
                                     @"boardFEN", @"fenAfterMove", @"currentPosition",
                                     @"positionFEN", @"boardPosition", @"gameFEN",
                                     @"getCurrentFen"];

            NSMutableArray *targets = [NSMutableArray arrayWithObject:self];
            UIResponder *r3 = [(UIView *)self nextResponder];
            int d3 = 0;
            while (r3 && d3 < 15) {
                [targets addObject:r3];
                r3 = [r3 nextResponder];
                d3++;
            }

            for (id target in targets) {
                for (NSString *selName in fenSelNames) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([target respondsToSelector:sel]) {
                        @try {
                            id result = getObj(target, sel);
                            if ([result isKindOfClass:[NSString class]] && [result length] > 10
                                && [result containsString:@"/"]) {
                                NSString *fen = (NSString *)result;
                                if ([fen isEqualToString:gLastEncoded]) return;
                                gLastEncoded = [fen copy];
                                parseFEN(fen);
                                currentFEN = fen;
                                static NSString *gLoggedFenSrc = nil;
                                NSString *src = [NSString stringWithFormat:@".%@ on %@", selName, NSStringFromClass([target class])];
                                if (![src isEqualToString:gLoggedFenSrc]) {
                                    gLoggedFenSrc = src;
                                    dbg([NSString stringWithFormat:@"FEN via %@", src]);
                                }
                                break;
                            }
                        } @catch (NSException *e) {}
                    }
                }
                if (currentFEN) break;
            }
        }

        if (!game && !currentFEN) {
            static NSString *gLastFailChain = nil;
            static NSDate *gLastFailLog = nil;
            BOOL shouldLog = NO;
            if (![chainLog isEqualToString:gLastFailChain]) shouldLog = YES;
            if (gLastFailLog && [[NSDate date] timeIntervalSinceDate:gLastFailLog] > 10.0) shouldLog = YES;
            if (!gLastFailLog) shouldLog = YES;
            if ([chainLog containsString:@"Puzzle"] && [NSStringFromClass([self class]) hasPrefix:@"CH"]) {
                gPuzzleBoard = (UIView *)self;
                if (drivePuzzle((UIView *)self)) return;
            }
            if (shouldLog && chainLog.length) {
                gLastFailChain = [chainLog copy];
                gLastFailLog = [NSDate date];
                dbg([NSString stringWithFormat:@"no game/FEN in chain: %@", chainLog]);
            }
            return;
        }

        if (!currentFEN) return;

        if (currentFEN.length) {

            if (gMyColor >= 0 && gMyColor != gSide) {

                MaiaNotePly([currentFEN UTF8String]);
                dispatch_async(dispatch_get_main_queue(), ^{ clearArrow(); });
                return;
            }
            dbg([NSString stringWithFormat:@"FEN: %@", [currentFEN substringToIndex:MIN(currentFEN.length, 55)]]);
            gForcedFlip = -1;

            gDrawBoard = gOnlineDrawBoard ?: resolveDrawBoard(boardSelf);
            fetchMove(currentFEN);
        }
    } @catch (NSException *ex) {
        dbg([NSString stringWithFormat:@"layout err: %@", ex.reason]);
    }
}

typedef void (*OrigSetEncoded)(id, SEL, NSString *);
static OrigSetEncoded gOrigSetEncoded = NULL;

static void hook_setEncodedMoves(id self, SEL _cmd, NSString *encoded) {
    if (gOrigSetEncoded) gOrigSetEncoded(self, _cmd, encoded);
    if (!gEnabled) return;
    if (!encoded) encoded = @"";
    @try {
        gOnlineGame = self;
        gOnlineSeen = [NSDate date];
        dumpMoveSelectors(self, @"game");
        typedef NSString *(*StrGetter)(id, SEL);
        StrGetter strGet = (StrGetter)objc_msgSend;
        SEL iFenSel = NSSelectorFromString(@"initialFEN");
        NSString *initialFEN = nil;
        if ([self respondsToSelector:iFenSel]) initialFEN = strGet(self, iFenSel);
        if (!initialFEN.length) initialFEN = @"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        NSString *currentFEN = decodeTCNToFEN(initialFEN, encoded);
        if (currentFEN.length) {
            parseFEN(currentFEN);
            if (gMyColor >= 0 && gMyColor != gSide) { MaiaNotePly([currentFEN UTF8String]); return; }
            dbg([NSString stringWithFormat:@"FEN(setter): %@", [currentFEN substringToIndex:MIN(currentFEN.length, 55)]]);
            gForcedFlip = -1;
            dispatch_async(dispatch_get_main_queue(), ^{ fetchMove(currentFEN); });
        }
    } @catch (NSException *ex) {
        dbg([NSString stringWithFormat:@"setter err: %@", ex.reason]);
    }
}

@interface CHAppDelegate : NSObject
- (void)applicationDidBecomeActive:(id)app;
@end

%hook CHAppDelegate
- (void)applicationDidBecomeActive:(id)app {
    %orig;
    loadPrefs();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        setupFloatingButton();

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if (![d boolForKey:PREF_SHOWN] || ![d boolForKey:PREF_CREDIT2]) {
            [d setBool:YES forKey:PREF_SHOWN];
            [d setBool:YES forKey:PREF_CREDIT2];
            [d synchronize];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                showCredits();
            });
        }
    });
}
%end

static void installBoardHooks(void) {
    NSArray *boardClassNames = @[
        @"CHBoardView",
        @"CHSoloBoardView",
        @"CHSimpleBoardView",
        @"CHDiagramBoardView",
        @"CHAnalysisBoardView"
    ];
    SEL layoutSel = @selector(layoutSubviews);
    for (NSString *name in boardClassNames) {
        if (gOrigLayouts[name]) continue;
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        Method m = class_getInstanceMethod(cls, layoutSel);
        if (!m) continue;

        OrigLayout orig = NULL;
        MSHookMessageEx(cls, layoutSel, (IMP)hook_layoutSubviews, (IMP *)&orig);
        if (orig) {
            gOrigLayouts[name] = [NSValue valueWithBytes:&orig objCType:@encode(OrigLayout)];
        }
        dbg([NSString stringWithFormat:@"HOOKED layoutSubviews on %@", name]);
    }

    static BOOL sSwiftBoardHooked = NO;
    if (!sSwiftBoardHooked) {
        unsigned int scCount = 0;
        Class *scClasses = objc_copyClassList(&scCount);
        for (unsigned int i = 0; i < scCount; i++) {
            NSString *scName = NSStringFromClass(scClasses[i]);

            if ([scName containsString:@"SwiftChessBoard"] &&
                ([scName containsString:@"BoardView"] || [scName hasSuffix:@"ChessBoard"])) {
                if (gOrigLayouts[scName]) { sSwiftBoardHooked = YES; continue; }
                Method m = class_getInstanceMethod(scClasses[i], layoutSel);
                if (!m) continue;
                OrigLayout orig = NULL;
                MSHookMessageEx(scClasses[i], layoutSel, (IMP)hook_layoutSubviews, (IMP *)&orig);
                if (orig) {
                    gOrigLayouts[scName] = [NSValue valueWithBytes:&orig objCType:@encode(OrigLayout)];
                }
                dbg([NSString stringWithFormat:@"HOOKED layoutSubviews on %@ (SwiftBoard)", scName]);
                sSwiftBoardHooked = YES;
            }
        }
        free(scClasses);
    }

    static BOOL sSwiftFenHooked = NO;
    if (!sSwiftFenHooked) {

        if (!gSwiftStringBridge) {
            gSwiftStringBridge = (SwiftStringBridgeFunc)dlsym(RTLD_DEFAULT,
                "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            if (gSwiftStringBridge) {
                dbg(@"Found Swift String bridge");
            } else {
                dbg(@"WARN: Swift String bridge NOT found");
            }
        }

        NSArray *fenSymbols = @[
            @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyF",
            @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyFTo",
            @"$s16EngineController04ChessB0C13getCurrentFenSSyF",
            @"$s16EngineController04ChessbC0C13getCurrentFenSSyF",
        ];
        for (NSString *sym in fenSymbols) {
            void *ptr = dlsym(RTLD_DEFAULT, sym.UTF8String);
            if (ptr) {
                MSHookFunction(ptr, (void *)hook_swiftGetFen, (void **)&gOrigSwiftGetFen);
                gSwiftHookActive = YES;
                sSwiftFenHooked = YES;
                dbg([NSString stringWithFormat:@"HOOKED Swift getCurrentFen: %@", sym]);
                break;
            }
        }

        if (!sSwiftFenHooked) {
            NSArray *tcnSymbols = @[
                @"$s16EngineController19ChessGameControllerC20getMainLineTcnStringSSyF",
                @"$s16EngineController04ChessB0C20getMainLineTcnStringSSyF",
            ];
            for (NSString *sym in tcnSymbols) {
                void *ptr = dlsym(RTLD_DEFAULT, sym.UTF8String);
                if (ptr) {
                    MSHookFunction(ptr, (void *)hook_swiftGetTcn, (void **)&gOrigSwiftGetTcn);
                    gSwiftHookActive = YES;
                    sSwiftFenHooked = YES;
                    dbg([NSString stringWithFormat:@"HOOKED Swift getMainLineTcnString: %@", sym]);
                    break;
                }
            }
        }

        if (!sSwiftFenHooked) {

            NSArray *broadSymbols = @[

                @"$s15ChessPlayBot19ChessGameControllerC13getCurrentFenSSyF",
                @"$s5Chess19ChessGameControllerC13getCurrentFenSSyF",
                @"$s9ChessGame19ChessGameControllerC13getCurrentFenSSyF",

                @"$s16EngineController14GameControllerC13getCurrentFenSSyF",
                @"$s16EngineController0B0C13getCurrentFenSSyF",

                @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyFTj",
                @"$s16EngineController19ChessGameControllerC13getCurrentFenSSyFTq",
            ];
            for (NSString *sym in broadSymbols) {
                void *ptr = dlsym(RTLD_DEFAULT, sym.UTF8String);
                if (ptr) {
                    MSHookFunction(ptr, (void *)hook_swiftGetFen, (void **)&gOrigSwiftGetFen);
                    gSwiftHookActive = YES;
                    sSwiftFenHooked = YES;
                    dbg([NSString stringWithFormat:@"HOOKED Swift FEN (broad): %@", sym]);
                    break;
                }
            }
        }

    }

    static BOOL sEncodedHooked = NO;
    if (!sEncodedHooked) {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        SEL target = NSSelectorFromString(@"setEncodedMoves:");
        for (unsigned int i = 0; i < count; i++) {
            if (class_getInstanceMethod(classes[i], target)) {
                NSString *name = NSStringFromClass(classes[i]);
                if ([name hasPrefix:@"UI"] || [name hasPrefix:@"NS"] || [name hasPrefix:@"_"]) continue;
                MSHookMessageEx(classes[i], target, (IMP)hook_setEncodedMoves, (IMP *)&gOrigSetEncoded);
                dbg([NSString stringWithFormat:@"HOOKED setEncodedMoves: on %@", name]);
                sEncodedHooked = YES;
                break;
            }
        }
        free(classes);
    }
}

%ctor {
    gLoadTime = [NSDate date];
    gOrigLayouts = [NSMutableDictionary dictionary];
    loadPrefs();
    dbg(@"loaded v2.5.2 (SF18 + Maia3)");
    EngineStart();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *candidates = maiaCandidatePaths();
        __block BOOL found = NO;
        for (NSString *c in candidates) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:c]) {
                found = YES;
                BOOL ok = MaiaLoad([c UTF8String]);
                dbg([NSString stringWithFormat:@"maia load %@: %@", ok ? @"OK" : @"FAIL", c]);
                break;
            }
        }
        if (!found) {
            dbg(@"maia: model not on disk — using embedded copy");
            BOOL ok = MaiaLoadEmbedded();
            dbg([NSString stringWithFormat:@"maia embedded load: %@", ok ? @"OK" : @"FAIL"]);
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installBoardHooks();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            enginePollTick();
        }];
        dbg(@"engine poller started");

    });
}
