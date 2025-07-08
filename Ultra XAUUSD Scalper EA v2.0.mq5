//+------------------------------------------------------------------+
//|                                 Ultra XAUUSD Scalper EA v2.0.mq5 |
//|            Optimized for M15 scalping with H1 trend confirmation |
//+------------------------------------------------------------------+
#property strict
#property version   "2.0"
#property description "Professional XAUUSD Scalper with Smart Adaptive Logic"
#property description "Combines multi-timeframe analysis with dynamic risk management"

#include <Trade/Trade.mqh>
#include <Indicators/Indicators.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "==== Risk Management ===="
input double   RiskPercent          = 0.5;       // Risk per trade (0.5-2%)
input double   MaxDailyRisk         = 3.0;       // Max daily risk (3%)
input int      MaxTradesPerDay      = 10;        // Max trades/day

input group "==== Trading Conditions ===="
input double   ATR_Threshold        = 1.8;       // Min ATR to trade ($1.80)
input int      MinTradeDistance     = 50;        // Min distance between trades (points)
input int      MaxSpread            = 45;        // Max allowed spread (points)
input bool     UseDynamicLotSize    = true;      // Use risk-based position sizing

input group "==== Trading Hours ===="
input int      LondonOpenHour       = 7;         // GMT London open
input int      NYCloseHour          = 17;        // GMT NY close
input bool     SkipLowVolatility    = true;      // Skip Asian session (2-5AM GMT)

input group "==== Strategy Parameters ===="
input int      TrendMA_Period       = 89;        // H1 Trend MA period
input int      SignalMA_Period      = 21;        // H1 Signal MA period
input int      Stoch_Period         = 5;         // Stochastic period (5-8)
input double   PivotZoneWidth       = 0.75;      // Pivot zone width ($0.75)
input bool     UseMACDConfirmation  = true;      // Additional MACD filter

input group "==== Trade Execution ===="
input double   SL_Multiplier        = 1.8;       // SL (x ATR)
input double   TP1_Multiplier       = 1.2;       // First TP (x SL)
input double   TP2_Multiplier       = 2.0;       // Second TP (x SL)
input double   TrailStart           = 0.8;       // Trail start (x TP1)
input double   TrailStep            = 0.3;       // Trail step ($0.30)

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade         trade;
int            magicNumber = 2025;
datetime       lastTradeTime = 0;
double         dailyProfit = 0;
int            dailyTrades = 0;
double         lastATR = 0;

// Indicator handles
int            atrHandle, maTrendHandle, maSignalHandle, stochHandle, macdHandle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize indicators
   atrHandle = iATR(_Symbol, PERIOD_M15, 14);
   maTrendHandle = iMA(_Symbol, PERIOD_H1, TrendMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   maSignalHandle = iMA(_Symbol, PERIOD_H1, SignalMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   stochHandle = iStochastic(_Symbol, PERIOD_M15, Stoch_Period, 3, 3, MODE_SMA, STO_LOWHIGH);
   macdHandle = iMACD(_Symbol, PERIOD_H1, 12, 26, 9, PRICE_CLOSE);

   // Configure trade settings
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetMarginMode();
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Set up daily reset timer
   EventSetTimer(60);
   ResetDailyStats();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Timer function for daily reset                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   MqlDateTime today;
   TimeCurrent(today);
   
   static int lastDay = -1;
   if(lastDay != today.day)
   {
      ResetDailyStats();
      lastDay = today.day;
   }
}

//+------------------------------------------------------------------+
//| Reset daily statistics                                           |
//+------------------------------------------------------------------+
void ResetDailyStats()
{
   dailyProfit = 0;
   dailyTrades = 0;
}

//+------------------------------------------------------------------+
//| Main tick processing                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Skip if not in trading session
   if(!IsOptimalTradingTime()) return;
   
   // Check spread limit
   if((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpread) return;
   
   // Manage open positions first
   ManageOpenPositions();
   
   // Check for new entry if no position exists
   if(!HasOpenPosition() && IsNewTradeAllowed())
   {
      CheckForEntry();
   }
   
   // Update dashboard
   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Check if current time is optimal for trading                     |
//+------------------------------------------------------------------+
bool IsOptimalTradingTime()
{
   MqlDateTime time;
   TimeCurrent(time);
   
   // Skip weekends
   if(time.day_of_week == SATURDAY || time.day_of_week == SUNDAY) return false;
   
   // Skip Friday after NY close
   if(time.day_of_week == FRIDAY && time.hour >= NYCloseHour) return false;
   
   // Skip Asian session if configured
   if(SkipLowVolatility && time.hour >= 2 && time.hour < 5) return false;
   
   // Only trade during London/NY overlap
   return (time.hour >= LondonOpenHour && time.hour < NYCloseHour);
}

//+------------------------------------------------------------------+
//| Check if new trade is allowed                                    |
//+------------------------------------------------------------------+
bool IsNewTradeAllowed()
{
   // Check daily limits
   if(dailyTrades >= MaxTradesPerDay) return false;
   
   // Check daily risk
   if(MathAbs(dailyProfit) >= AccountInfoDouble(ACCOUNT_EQUITY) * MaxDailyRisk / 100.0) return false;
   
   // Check minimum time/distance from last trade
   if(lastTradeTime > 0 && TimeCurrent() - lastTradeTime < MinTradeDistance * 60) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Smart entry logic with multiple confirmations                    |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   // Get volatility filter
   double atrValue = GetIndicatorValue(atrHandle, 0);
   if(atrValue < ATR_Threshold) return;
   lastATR = atrValue;
   
   // Get trend direction
   double maTrend = GetIndicatorValue(maTrendHandle, 0);
   double maSignal = GetIndicatorValue(maSignalHandle, 0);
   bool uptrend = maSignal > maTrend;
   bool downtrend = maSignal < maTrend;
   
   // Get stochastic values
   double stochMain = GetIndicatorValue(stochHandle, 0, 0);
   double stochSignal = GetIndicatorValue(stochHandle, 1, 0);
   double stochMainPrev = GetIndicatorValue(stochHandle, 0, 1);
   double stochSignalPrev = GetIndicatorValue(stochHandle, 1, 1);
   
   // Get MACD confirmation if enabled
   bool macdBullish = true, macdBearish = true;
   if(UseMACDConfirmation)
   {
      double macdMain = GetIndicatorValue(macdHandle, 0, 0);
      double macdSignal = GetIndicatorValue(macdHandle, 1, 0);
      macdBullish = macdMain > macdSignal;
      macdBearish = macdMain < macdSignal;
   }
   
   // Get current price and pivots
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pivots[7];
   GetDailyPivots(pivots);
   
   // Check long conditions
   if(uptrend && macdBullish)
   {
      bool inBuyZone = IsInPivotZone(bid, pivots, true);
      bool stochConfirm = stochMain > stochSignal && stochMainPrev <= stochSignalPrev && stochMain < 25;
      
      if(inBuyZone && stochConfirm)
      {
         ExecuteTrade(ORDER_TYPE_BUY, ask, atrValue);
      }
   }
   // Check short conditions
   else if(downtrend && macdBearish)
   {
      bool inSellZone = IsInPivotZone(bid, pivots, false);
      bool stochConfirm = stochMain < stochSignal && stochMainPrev >= stochSignalPrev && stochMain > 75;
      
      if(inSellZone && stochConfirm)
      {
         ExecuteTrade(ORDER_TYPE_SELL, bid, atrValue);
      }
   }
}

//+------------------------------------------------------------------+
//| Advanced trade execution with smart position sizing              |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double price, double atrValue)
{
   // Calculate position size
   double stopDistance = SL_Multiplier * atrValue;
   double volume = 0.1; // Default fixed lot size
    
   if(UseDynamicLotSize)
   {
      double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;
      volume = NormalizeDouble(riskAmount / (stopDistance * 100.0), 2);
      
      // Adjust volume to broker limits
      double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      volume = MathMax(minVolume, MathMin(volume, maxVolume));
   }
   
   // Calculate SL and TP
   double sl = (type == ORDER_TYPE_BUY) ? price - stopDistance : price + stopDistance;
   double tp1 = (type == ORDER_TYPE_BUY) ? price + stopDistance * TP1_Multiplier : 
                                          price - stopDistance * TP1_Multiplier;
   
   // Execute trade with comment containing trade details
   string comment = StringFormat("XAU_SCALP_v2;ATR=%.2f;SL=%.2f;TP1=%.2f", atrValue, sl, tp1);
   
   if(trade.PositionOpen(_Symbol, type, volume, price, sl, 0, comment))
   {
      lastTradeTime = TimeCurrent();
      dailyTrades++;
      Print("Trade executed: ", EnumToString(type), " at ", DoubleToString(price, 2), 
            " | SL: ", DoubleToString(sl, 2), " | TP1: ", DoubleToString(tp1, 2));
   }
   else
   {
      Print("Trade failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Advanced position management with dynamic trailing               |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!PositionSelect(_Symbol)) return;
   
   ulong ticket = PositionGetTicket(0);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentPrice = PositionGetDouble(POSITION_TYPE) == POSITION_TYPE_BUY ? 
                        SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   string comment = PositionGetString(POSITION_COMMENT);
   
   // Parse trade details from comment
   double atrValue = 0, initialSL = 0, tp1Level = 0;
   if(StringFind(comment, "ATR=") != -1)
      atrValue = StringToDouble(StringSubstr(comment, StringFind(comment, "ATR=") + 4));
   if(StringFind(comment, "SL=") != -1)
      initialSL = StringToDouble(StringSubstr(comment, StringFind(comment, "SL=") + 3));
   if(StringFind(comment, "TP1=") != -1)
      tp1Level = StringToDouble(StringSubstr(comment, StringFind(comment, "TP1=") + 4));
   
   // Calculate TP1 if not parsed
   if(tp1Level == 0 && atrValue != 0)
   {
      double stopDistance = MathAbs(openPrice - initialSL);
      tp1Level = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                 openPrice + stopDistance * TP1_Multiplier :
                 openPrice - stopDistance * TP1_Multiplier;
   }
   
   // Check for TP1 hit (first profit target)
   if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && currentPrice >= tp1Level) ||
      (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && currentPrice <= tp1Level))
   {
      // Close 50% position if not already done
      if(StringFind(comment, "PHASE2") == -1)
      {
         double closeVolume = NormalizeDouble(PositionGetDouble(POSITION_VOLUME) / 2, 2);
         if(trade.PositionClosePartial(ticket, closeVolume))
         {
            // Modify remaining position to breakeven with trail
            string newComment = comment + ";PHASE2";
            trade.PositionModify(ticket, openPrice, 0, newComment);
            Print("Partial close executed at TP1: ", DoubleToString(tp1Level, 2));
         }
      }
   }
   
   // Apply trailing stop for remaining position after TP1 hit
   if(StringFind(comment, "PHASE2") != -1)
   {
      double trailLevel = 0;
      double trailStart = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ?
                         openPrice + (tp1Level - openPrice) * TrailStart :
                         openPrice - (openPrice - tp1Level) * TrailStart;
      
      if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && currentPrice >= trailStart) ||
         (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && currentPrice <= trailStart))
      {
         // Calculate new trail level
         trailLevel = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                     currentPrice - TrailStep :
                     currentPrice + TrailStep;
         
         // Only move trail if favorable
         if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && trailLevel > currentSL) ||
            (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && trailLevel < currentSL))
         {
            trade.PositionModify(ticket, trailLevel, 0, comment);
         }
      }
   }
   
   // Check for TP2 hit (final profit target)
   double tp2Level = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                    openPrice + MathAbs(openPrice - initialSL) * TP2_Multiplier :
                    openPrice - MathAbs(openPrice - initialSL) * TP2_Multiplier;
   
   if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && currentPrice >= tp2Level) ||
      (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && currentPrice <= tp2Level))
   {
      trade.PositionClose(ticket);
      double profit = PositionGetDouble(POSITION_PROFIT);
      dailyProfit += profit;
      Print("Final TP hit at ", DoubleToString(tp2Level, 2), " | Profit: ", DoubleToString(profit, 2));
   }
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int buffer=0, int shift=0)
{
   double value[1];
   if(CopyBuffer(handle, buffer, shift, 1, value) == 1)
      return value[0];
   return EMPTY_VALUE;
}

void GetDailyPivots(double &pivots[])
{
   MqlRates prevDay[];
   ArraySetAsSeries(prevDay, true);
   CopyRates(_Symbol, PERIOD_D1, 1, 1, prevDay);
   
   double H = prevDay[0].high;
   double L = prevDay[0].low;
   double C = prevDay[0].close;
   
   pivots[0] = (H + L + C) / 3; // Pivot
   pivots[1] = 2 * pivots[0] - L; // R1
   pivots[2] = pivots[0] + (H - L); // R2
   pivots[3] = H + 2 * (pivots[0] - L); // R3
   pivots[4] = 2 * pivots[0] - H; // S1
   pivots[5] = pivots[0] - (H - L); // S2
   pivots[6] = L - 2 * (H - pivots[0]); // S3
}

bool IsInPivotZone(double price, double &pivots[], bool support)
{
   for(int i = (support ? 4 : 0); i < (support ? 7 : 3); i++)
   {
      if(MathAbs(price - pivots[i]) <= PivotZoneWidth)
         return true;
   }
   return false;
}

bool HasOpenPosition()
{
   return PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == magicNumber;
}

//+------------------------------------------------------------------+
//| Professional dashboard with real-time analytics                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   string dashboardText = "\n\n=== XAUUSD ULTRA SCALPER v2.0 ===";
   dashboardText += "\nTrading Session: " + (IsOptimalTradingTime() ? "ACTIVE" : "CLOSED");
   dashboardText += "\nDaily Stats: Trades " + IntegerToString(dailyTrades) + "/" + IntegerToString(MaxTradesPerDay);
   dashboardText += " | P/L: " + DoubleToString(dailyProfit, 2);
   
   // Market conditions
   dashboardText += "\n\n=== MARKET CONDITIONS ===";
   dashboardText += "\nATR(14): " + DoubleToString(lastATR, 2) + " (" + (lastATR >= ATR_Threshold ? "Good" : "Low") + " volatility)";
   dashboardText += "\nSpread: " + IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " points";
   
   // Trend information
   double maTrend = GetIndicatorValue(maTrendHandle, 0);
   double maSignal = GetIndicatorValue(maSignalHandle, 0);
   string trendDirection = (maSignal > maTrend) ? "BULLISH" : "BEARISH";
   dashboardText += "\nTrend: " + trendDirection + " | Signal MA: " + DoubleToString(maSignal, 2);
   
   // Last trade info
   if(lastTradeTime > 0)
   {
      dashboardText += "\n\nLast Trade: " + TimeToString(lastTradeTime, TIME_MINUTES);
      dashboardText += " | " + (PositionSelect(_Symbol) ? "Active" : "Closed");
   }
   
   Comment(dashboardText);
}

//+------------------------------------------------------------------+