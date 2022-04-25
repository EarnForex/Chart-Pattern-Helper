//+------------------------------------------------------------------+
//|                                             Chart Pattern Helper |
//|                             Copyright © 2013-2022, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2013-2022, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/ChartPatternHelper/"
#property version   "1.10"

#property description "Uses graphic objects (horizontal/trend lines, channels) to enter trades."
#property description "Works in two modes:"
#property description "1. Price is below upper entry and above lower entry. Only one or two pending stop orders are used."
#property description "2. Price is above upper entry or below lower entry. Only one pending limit order is used."
#property description "If an object is deleted/renamed after the pending order was placed, order will be canceled."
#property description "Pending order is removed if opposite entry is triggered."
#property description "Generally, it is safe to turn off the EA at any point."

#include <Trade/Trade.mqh>
#include <Trade/OrderInfo.mqh>

input group "Objects"
input string UpperBorderLine = "UpperBorder";
input string UpperEntryLine = "UpperEntry";
input string UpperTPLine = "UpperTP";
input string LowerBorderLine = "LowerBorder";
input string LowerEntryLine = "LowerEntry";
input string LowerTPLine = "LowerTP";
// The pattern may be given as trend/horizontal lines or equidistant channels.
input string BorderChannel = "Border";
input string EntryChannel = "Entry";
input string TPChannel = "TP";
input group "Order management"
// In case Channel is used for Entry, pending orders will be removed even if OneCancelsOther = false.
input bool OneCancelsOther = true; // OneCancelsOther: Remove opposite orders once position is open?
// If true, spread will be added to Buy entry level and Sell SL/TP levels. It compensates the difference when Ask price is used, while all chart objects are drawn at Bid level.
input bool UseSpreadAdjustment = false; // UseSpreadAdjustment: Add spread to Buy entry and Sell SL/TP?
// Not all brokers support expiration.
input bool UseExpiration = true; // UseExpiration: Use expiration on pending orders?
input bool DisableBuyOrders = false; // DisableBuyOrders: Disable new and ignore existing buy trades?
input bool DisableSellOrders = false; // DisableSellOrders: Disable new and ignore existing sell trades?
// If true, the EA will try to adjust SL after breakout candle is complete as it may no longer qualify for SL; it will make SL more precise but will mess up the money management a bit.
input bool PostEntrySLAdjustment = false; // PostEntrySLAdjustment: Adjust SL after entry?
input bool UseDistantSL = false; // UseDistantSL: If true, set SL to pattern's farthest point.
input group "Trendline trading"
input bool OpenOnCloseAboveBelowTrendline = false; // Open trade on close above/below trendline.
input string SLLine = "SL"; // Stop-loss line name for trendline trading.
input int ThresholdSpreads = 10; // Threshold Spreads: number of spreads for minimum distance.
input group "Position sizing"
input bool CalculatePositionSize = true; // CalculatePositionSize: Use money management module?
input bool UpdatePendingVolume = true; // UpdatePendingVolume: If true, recalculate pending order volume.
input double FixedPositionSize = 0.01; // FixedPositionSize: Used if CalculatePositionSize = false.
input double Risk = 1; // Risk: Risk tolerance in percentage points.
input double MoneyRisk = 0; // MoneyRisk: Risk tolerance in base currency.
input bool UseMoneyInsteadOfPercentage = false;
input bool UseEquityInsteadOfBalance = false;
input double FixedBalance = 0; // FixedBalance: If > 0, trade size calc. uses it as balance.
input group "Miscellaneous"
input int Magic = 20200530;
input int Slippage = 30; // Slippage: Maximum slippage in broker's pips.
input bool Silent = false; // Silent: If true, does not display any output via chart comment.
input bool ErrorLogging = true; // ErrorLogging: If true, errors will be logged to file.

// Global variables:
bool UseUpper, UseLower;
double UpperSL, UpperEntry, UpperTP, LowerSL, LowerEntry, LowerTP;
ulong UpperTicket, LowerTicket;
bool HaveBuyPending = false;
bool HaveSellPending = false;
bool HaveBuy = false;
bool HaveSell = false;
bool TDisabled = false; // Trading disabled.
bool ExpirationEnabled = UseExpiration;
bool PostBuySLAdjustmentDone = false, PostSellSLAdjustmentDone = false;
// For tick value adjustment.
string AccountCurrency = "";
string ProfitCurrency = "";
string BaseCurrency = "";
ENUM_SYMBOL_CALC_MODE CalcMode;
string ReferencePair = NULL;
bool ReferenceSymbolMode;

// MT5 specific:
datetime Time[];
double High[], Low[], Close[];
int SecondsPerBar = 0;
CTrade *Trade;
COrderInfo OrderInfo;

// For error logging:
string filename;

void OnInit()
{
    PrepareTimeseries();
    FindObjects();
    SecondsPerBar = PeriodSeconds();
    Trade = new CTrade;
    Trade.SetDeviationInPoints(Slippage);
    Trade.SetExpertMagicNumber(Magic);

    // Do not use expiration if broker does not allow it.
    int exp_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
    if ((exp_mode & 4) != 4) ExpirationEnabled = false;

    if (ErrorLogging)
    {
        // Creating filename for error logging
        MqlDateTime dt;
        TimeToStruct(TimeLocal(), dt);
        filename = "CPH-Errors-" + IntegerToString(dt.year) + IntegerToString(dt.mon, 2, '0') + IntegerToString(dt.day, 2, '0') + IntegerToString(dt.hour, 2, '0') + IntegerToString(dt.min, 2, '0') + IntegerToString(dt.sec, 2, '0') + ".log";
    }
}

void OnDeinit(const int reason)
{
    SetComment("");
    delete Trade;
}

void OnTick()
{
    DoRoutines();
}

void OnChartEvent(const int id,         // Event ID
                  const long& lparam,   // Parameter of type long event
                  const double& dparam, // Parameter of type double event
                  const string& sparam  // Parameter of type string events
                 )
{
    // If not an object change.
    if ((id != CHARTEVENT_OBJECT_DRAG) && (id != CHARTEVENT_OBJECT_CREATE) && (id != CHARTEVENT_OBJECT_CHANGE) && (id != CHARTEVENT_OBJECT_DELETE) && (id != CHARTEVENT_OBJECT_ENDEDIT)) return;
    // If not EA's objects.
    if ((sparam != UpperBorderLine) && (sparam != UpperEntryLine) && (sparam != UpperTPLine) && (sparam != LowerBorderLine) && (sparam != LowerEntryLine) && (sparam != LowerTPLine) && (sparam != BorderChannel) && (sparam != EntryChannel) && (sparam != TPChannel)) return;

    DoRoutines();
}

//+------------------------------------------------------------------+
//| Main handling function                                           |
//+------------------------------------------------------------------+
void DoRoutines()
{
    PrepareTimeseries();
    FindOrders();
    FindObjects();
    AdjustOrders(); // And delete the ones no longer needed.
}

// Finds Entry, Border and TP objects. Detects respective levels according to found objects. Outputs found values to chart comment.
void FindObjects()
{
    string c1 = FindUpperObjects();
    string c2 = FindLowerObjects();

    SetComment(c1 + c2);
}

// Adjustment for Ask/Bid spread is made for entry level as Long positions are entered at Ask, while all objects are drawn at Bid.
string FindUpperObjects()
{
    string c = ""; // Text for chart comment

    if (DisableBuyOrders)
    {
        UseUpper = false;
        return "\nBuy orders disabled via input parameters.";
    }

    UseUpper = true;

    // Entry.
    if (OpenOnCloseAboveBelowTrendline) // Simple trendline entry doesn't need an entry line.
    {
        c = c + "\nUpper entry unnecessary.";
    }
    else if (ObjectFind(0, UpperEntryLine) > -1)
    {
        if ((ObjectGetInteger(0, UpperEntryLine, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, UpperEntryLine, OBJPROP_TYPE) != OBJ_TREND))
        {
            Alert("Upper Entry Line should be either OBJ_HLINE or OBJ_TREND.");
            return("\nWrong Upper Entry Line object type.");
        }
        if (ObjectGetInteger(0, UpperEntryLine, OBJPROP_TYPE) != OBJ_HLINE) UpperEntry = NormalizeDouble(ObjectGetValueByTime(0, UpperEntryLine, Time[0], 0), _Digits);
        else UpperEntry = NormalizeDouble(ObjectGetDouble(0, UpperEntryLine, OBJPROP_PRICE, 0), _Digits); // Horizontal line value
        if (UseSpreadAdjustment) UpperEntry = NormalizeDouble(UpperEntry + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, _Digits);
        ObjectSetInteger(0, UpperEntryLine, OBJPROP_RAY_LEFT, true);
        ObjectSetInteger(0, UpperEntryLine, OBJPROP_RAY_RIGHT, true);
        c += "\nUpper entry found. Level: " + DoubleToString(UpperEntry, _Digits);
    }
    else
    {
        if (ObjectFind(0, EntryChannel) > -1)
        {
            if (ObjectGetInteger(0, EntryChannel, OBJPROP_TYPE) != OBJ_CHANNEL)
            {
                Alert("Entry Channel should be OBJ_CHANNEL.");
                return "\nWrong Entry Channel object type.";
            }
            UpperEntry = NormalizeDouble(FindUpperEntryViaChannel(), _Digits);
            if (UseSpreadAdjustment) UpperEntry = NormalizeDouble(UpperEntry + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, _Digits);
            ObjectSetInteger(0, EntryChannel, OBJPROP_RAY_LEFT, true);
            ObjectSetInteger(0, EntryChannel, OBJPROP_RAY_RIGHT, true);
            c = c + "\nUpper entry found (via channel). Level: " + DoubleToString(UpperEntry, _Digits);
        }
        else
        {
            c = c + "\nUpper entry not found. No new position will be entered.";
            UseUpper = false;
        }
    }

    // Border
    if (ObjectFind(0, UpperBorderLine) > -1)
    {
        if ((ObjectGetInteger(0, UpperBorderLine, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, UpperBorderLine, OBJPROP_TYPE) != OBJ_TREND))
        {
            Alert("Upper Border Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Upper Border Line object type.";
        }
        // Find upper SL
        UpperSL = FindUpperSL();
        ObjectSetInteger(0, UpperBorderLine, OBJPROP_RAY_LEFT, true);
        ObjectSetInteger(0, UpperBorderLine, OBJPROP_RAY_RIGHT, true);
        c = c + "\nUpper border found. Upper stop-loss level: " + DoubleToString(UpperSL, _Digits);
    }
    else // Try to find a channel
    {
        if (ObjectFind(0, BorderChannel) > -1)
        {
            if (ObjectGetInteger(0, BorderChannel, OBJPROP_TYPE) != OBJ_CHANNEL)
            {
                Alert("Border Channel should be OBJ_CHANNEL.");
                return "\nWrong Border Channel object type.";
            }
            // Find upper SL
            UpperSL = FindUpperSLViaChannel();
            ObjectSetInteger(0, BorderChannel, OBJPROP_RAY_LEFT, true);
            ObjectSetInteger(0, BorderChannel, OBJPROP_RAY_RIGHT, true);
            c = c + "\nUpper border found (via channel). Upper stop-loss level: " + DoubleToString(UpperSL, _Digits);
        }
        else
        {
            c = c + "\nUpper border not found.";
            if ((CalculatePositionSize) && (!HaveBuy))
            {
                UseUpper = false;
                c = c + " Cannot trade without stop-loss, while CalculatePositionSize set to true.";
            }
            else
            {
                c = c + " Stop-loss won\'t be applied to new positions.";
                // Track current SL, possibly installed by user
                if ((OrderInfo.Select(UpperTicket)) && (OrderInfo.State() == ORDER_STATE_PLACED))
                {
                    UpperSL = OrderInfo.StopLoss();
                }
            }
        }
    }
    // Adjust upper SL for tick size granularity.
    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    UpperSL = NormalizeDouble(MathRound(UpperSL / TickSize) * TickSize, _Digits);

    // Take-profit
    if (ObjectFind(0, UpperTPLine) > -1)
    {
        if ((ObjectGetInteger(0, UpperTPLine, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, UpperTPLine, OBJPROP_TYPE) != OBJ_TREND))
        {
            Alert("Upper TP Line should be either OBJ_HLINE or OBJ_TREND.");
            return("\nWrong Upper TP Line object type.");
        }
        if (ObjectGetInteger(0, UpperTPLine, OBJPROP_TYPE) != OBJ_HLINE) UpperTP = NormalizeDouble(ObjectGetValueByTime(0, UpperTPLine, Time[0], 0), _Digits);
        else UpperTP = NormalizeDouble(ObjectGetDouble(0, UpperTPLine, OBJPROP_PRICE, 0), _Digits); // Horizontal line value
        ObjectSetInteger(0, UpperTPLine, OBJPROP_RAY_LEFT, true);
        ObjectSetInteger(0, UpperTPLine, OBJPROP_RAY_RIGHT, true);
        c = c + "\nUpper take-profit found. Level: " + DoubleToString(UpperTP, _Digits);
    }
    else
    {
        if (ObjectFind(0, TPChannel) > -1)
        {
            if (ObjectGetInteger(0, TPChannel, OBJPROP_TYPE) != OBJ_CHANNEL)
            {
                Alert("TP Channel should be OBJ_CHANNEL.");
                return "\nWrong TP Channel object type.";
            }
            UpperTP = FindUpperTPViaChannel();
            ObjectSetInteger(0, TPChannel, OBJPROP_RAY_LEFT, true);
            ObjectSetInteger(0, TPChannel, OBJPROP_RAY_RIGHT, true);
            c = c + "\nUpper TP found (via channel). Level: " + DoubleToString(UpperTP, _Digits);
        }
        else
        {
            c = c + "\nUpper take-profit not found. Take-profit won\'t be applied to new positions.";
            // Track current TP, possibly installed by user.
            if ((OrderInfo.Select(UpperTicket)) && (OrderInfo.State() == ORDER_STATE_PLACED))
            {
                UpperTP = OrderInfo.TakeProfit();
            }
        }
    }
    // Adjust upper TP for tick size granularity.
    UpperTP = NormalizeDouble(MathRound(UpperTP / TickSize) * TickSize, _Digits);

    return c;
}

// Adjustment for Ask/Bid spread is made for exit levels (SL and TP) as Short positions are exited at Ask, while all objects are drawn at Bid.
string FindLowerObjects()
{
    string c = ""; // Text for chart comment

    if (DisableSellOrders)
    {
        UseLower = false;
        return "\nSell orders disabled via input parameters.";
    }

    UseLower = true;

    // Entry.
    if (OpenOnCloseAboveBelowTrendline) // Simple trendline entry doesn't need an entry line.
    {
        c = c + "\nLower entry unnecessary.";
    }
    else if (ObjectFind(0, LowerEntryLine) > -1)
    {
        if ((ObjectGetInteger(0, LowerEntryLine, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, LowerEntryLine, OBJPROP_TYPE) != OBJ_TREND))
        {
            Alert("Lower Entry Line should be either OBJ_HLINE or OBJ_TREND.");
            return("\nWrong Lower Entry Line object type.");
        }
        if (ObjectGetInteger(0, LowerEntryLine, OBJPROP_TYPE) != OBJ_HLINE) LowerEntry = NormalizeDouble(ObjectGetValueByTime(0, LowerEntryLine, Time[0], 0), _Digits);
        else LowerEntry = NormalizeDouble(ObjectGetDouble(0, LowerEntryLine, OBJPROP_PRICE, 0), _Digits); // Horizontal line value
        ObjectSetInteger(0, LowerEntryLine, OBJPROP_RAY_LEFT, true);
        ObjectSetInteger(0, LowerEntryLine, OBJPROP_RAY_RIGHT, true);
        c = c + "\nLower entry found. Level: " + DoubleToString(LowerEntry, _Digits);
    }
    else
    {
        if (ObjectFind(0, EntryChannel) > -1)
        {
            if (ObjectGetInteger(0, EntryChannel, OBJPROP_TYPE) != OBJ_CHANNEL)
            {
                Alert("Entry Channel should be OBJ_CHANNEL.");
                return "\nWrong Entry Channel object type.";
            }
            LowerEntry = FindLowerEntryViaChannel();
            ObjectSetInteger(0, EntryChannel, OBJPROP_RAY_LEFT, true);
            ObjectSetInteger(0, EntryChannel, OBJPROP_RAY_RIGHT, true);
            c = c + "\nLower entry found (via channel). Level: " + DoubleToString(LowerEntry, _Digits);
        }
        else
        {
            c = c + "\nLower entry not found. No new position will be entered.";
            UseLower = false;
        }
    }

    // Border
    if (ObjectFind(0, LowerBorderLine) > -1)
    {
        if ((ObjectGetInteger(0, LowerBorderLine, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, LowerBorderLine, OBJPROP_TYPE) != OBJ_TREND))
        {
            Alert("Lower Border Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Lower Border Line object type.";
        }
        // Find Lower SL
        LowerSL = NormalizeDouble(FindLowerSL(), _Digits);
        if (UseSpreadAdjustment) LowerSL = NormalizeDouble(LowerSL + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, _Digits);
        ObjectSetInteger(0, LowerBorderLine, OBJPROP_RAY_LEFT, true);
        ObjectSetInteger(0, LowerBorderLine, OBJPROP_RAY_RIGHT, true);
        c = c + "\nLower border found. Lower stop-loss level: " + DoubleToString(LowerSL, _Digits);
    }
    else // Try to find a channel
    {
        if (ObjectFind(0, BorderChannel) > -1)
        {
            if (ObjectGetInteger(0, BorderChannel, OBJPROP_TYPE) != OBJ_CHANNEL)
            {
                Alert("Border Channel should be OBJ_CHANNEL.");
                return "\nWrong Border Channel object type.";
            }
            // Find Lower SL
            LowerSL = NormalizeDouble(FindLowerSLViaChannel(), _Digits);
            if (UseSpreadAdjustment) LowerSL = NormalizeDouble(LowerSL + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, _Digits);
            ObjectSetInteger(0, BorderChannel, OBJPROP_RAY_LEFT, true);
            ObjectSetInteger(0, BorderChannel, OBJPROP_RAY_RIGHT, true);
            c = c + "\nLower border found (via channel). Lower stop-loss level: " + DoubleToString(LowerSL, _Digits);
        }
        else
        {
            c = c + "\nLower border not found.";
            if ((CalculatePositionSize) && (!HaveSell))
            {
                UseLower = false;
                c = c + " Cannot trade without stop-loss, while CalculatePositionSize set to true.";
            }
            else
            {
                c = c + " Stop-loss won\'t be applied to new positions.";
                // Track current SL, possibly installed by user
                if ((OrderInfo.Select(LowerTicket)) && (OrderInfo.State() == ORDER_STATE_PLACED))
                {
                    LowerSL = OrderInfo.StopLoss();
                }
            }
        }
    }
    // Adjust lower SL for tick size granularity.
    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    LowerSL = NormalizeDouble(MathRound(LowerSL / TickSize) * TickSize, _Digits);

    // Take-profit
    if (ObjectFind(0, LowerTPLine) > -1)
    {
        if ((ObjectGetInteger(0, LowerTPLine, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, LowerTPLine, OBJPROP_TYPE) != OBJ_TREND))
        {
            Alert("Lower TP Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Lower TP Line object type.";
        }
        if (ObjectGetInteger(0, LowerTPLine, OBJPROP_TYPE) != OBJ_HLINE) LowerTP = NormalizeDouble(ObjectGetValueByTime(0, LowerTPLine, Time[0], 0), _Digits);
        else LowerTP = NormalizeDouble(ObjectGetDouble(0, LowerTPLine, OBJPROP_PRICE, 0), _Digits); // Horizontal line value
        if (UseSpreadAdjustment) LowerTP = NormalizeDouble(LowerTP + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, _Digits);
        ObjectSetInteger(0, LowerTPLine, OBJPROP_RAY_LEFT, true);
        ObjectSetInteger(0, LowerTPLine, OBJPROP_RAY_RIGHT, true);
        c = c + "\nLower take-profit found. Level: " + DoubleToString(LowerTP, _Digits);
    }
    else
    {
        if (ObjectFind(0, TPChannel) > -1)
        {
            if (ObjectGetInteger(0, TPChannel, OBJPROP_TYPE) != OBJ_CHANNEL)
            {
                Alert("TP Channel should be OBJ_CHANNEL.");
                return "\nWrong TP Channel object type.";
            }
            LowerTP = NormalizeDouble(FindLowerTPViaChannel(), _Digits);
            if (UseSpreadAdjustment) LowerTP = NormalizeDouble(LowerTP + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, _Digits);
            ObjectSetInteger(0, TPChannel, OBJPROP_RAY_LEFT, true);
            ObjectSetInteger(0, TPChannel, OBJPROP_RAY_RIGHT, true);
            c = c + "\nLower TP found (via channel). Level: " + DoubleToString(LowerTP, _Digits);
        }
        else
        {
            c = c + "\nLower take-profit not found. Take-profit won\'t be applied to new positions.";
            // Track current TP, possibly installed by user
            if ((OrderInfo.Select(LowerTicket)) && (OrderInfo.State() == ORDER_STATE_PLACED))
            {
                LowerTP = OrderInfo.TakeProfit();
            }
        }
    }
    // Adjust lower TP for tick size granularity.
    LowerTP = NormalizeDouble(MathRound(LowerTP / TickSize) * TickSize, _Digits);

    return c;
}

// Find SL using a border line - the low of the first bar with major part below border.
double FindUpperSL()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double SL = -1;

    // Everything becomes much easier if the EA just needs to find the farthest opposite point of the pattern.
    if (UseDistantSL)
    {
        // Horizontal line.
        if (ObjectGetInteger(0, LowerBorderLine, OBJPROP_TYPE) == OBJ_HLINE)
        {
            return NormalizeDouble(ObjectGetDouble(0, LowerBorderLine, OBJPROP_PRICE, 0), _Digits);
        }
        // Trend line.
        else if (ObjectGetInteger(0, LowerBorderLine, OBJPROP_TYPE) == OBJ_TREND)
        {
            double price1 = ObjectGetDouble(0, LowerBorderLine, OBJPROP_PRICE, 0);
            double price2 = ObjectGetDouble(0, LowerBorderLine, OBJPROP_PRICE, 1);
            if (price1 < price2) return(NormalizeDouble(price1, _Digits));
            else return NormalizeDouble(price2, _Digits);
        }
    }

    // Easy stop-loss via a separate horizontal line when using trendline trading.
    if (OpenOnCloseAboveBelowTrendline)
    {
        if (ObjectFind(0, SLLine) < 0) return -1;
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE, 0), _Digits);
    }

    for (int i = 0; i < Bars(_Symbol, _Period); i++)
    {
        double Border, Entry;
        if (ObjectGetInteger(0, UpperBorderLine, OBJPROP_TYPE) != OBJ_HLINE) Border = ObjectGetValueByTime(0, UpperBorderLine, Time[i], 0);
        else Border = ObjectGetDouble(0, UpperBorderLine, OBJPROP_PRICE, 0); // Horizontal line value
        if (ObjectGetInteger(0, UpperEntryLine, OBJPROP_TYPE) != OBJ_HLINE) Entry = ObjectGetValueByTime(0, UpperEntryLine, Time[i], 0);
        else Entry = ObjectGetDouble(0, UpperEntryLine, OBJPROP_PRICE, 0); // Horizontal line value
        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next bar's Low should be lower or equal to that of the first bar.
        if ((Border - Low[i] > High[i] - Border) && ((Entry - Border < Border - Low[i]) || (i != 0)) && (Low[i] <= Low[0])) return NormalizeDouble(Low[i], _Digits);
    }

    return SL;
}

// Find SL using a border line - the high of the first bar with major part above border.
double FindLowerSL()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double SL = -1;

    // Everything becomes much easier if the EA just needs to find the farthest opposite point of the pattern.
    if (UseDistantSL)
    {
        // Horizontal line.
        if (ObjectGetInteger(0, UpperBorderLine, OBJPROP_TYPE) == OBJ_HLINE)
        {
            return NormalizeDouble(ObjectGetDouble(0, UpperBorderLine, OBJPROP_PRICE, 0), _Digits);
        }
        // Trend line.
        else if (ObjectGetInteger(0, UpperBorderLine, OBJPROP_TYPE) == OBJ_TREND)
        {
            double price1 = ObjectGetDouble(0, UpperBorderLine, OBJPROP_PRICE, 0);
            double price2 = ObjectGetDouble(0, UpperBorderLine, OBJPROP_PRICE, 1);
            if (price1 > price2) return NormalizeDouble(price1, _Digits);
            else return NormalizeDouble(price2, _Digits);
        }
    }

    // Easy stop-loss via a separate horizontal line when using trendline trading.
    if (OpenOnCloseAboveBelowTrendline)
    {
        if (ObjectFind(0, SLLine) < 0) return -1;
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE, 0), _Digits);
    }

    for (int i = 0; i < Bars(_Symbol, _Period); i++)
    {
        double Border, Entry;
        if (ObjectGetInteger(0, LowerBorderLine, OBJPROP_TYPE) != OBJ_HLINE) Border = ObjectGetValueByTime(0, LowerBorderLine, Time[i], 0);
        else Border = ObjectGetDouble(0, LowerBorderLine, OBJPROP_PRICE, 0); // Horizontal line value
        if (ObjectGetInteger(0, LowerEntryLine, OBJPROP_TYPE) != OBJ_HLINE) Entry = ObjectGetValueByTime(0, LowerEntryLine, Time[i], 0);
        else Entry = ObjectGetDouble(0, LowerEntryLine, OBJPROP_PRICE, 0); // Horizontal line value
        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next bar's High should be higher or equal to that of the first bar.
        if ((High[i] - Border > Border - Low[i]) && ((Border - Entry < High[i] - Border) || (i != 0)) && (High[i] >= High[0])) return NormalizeDouble(High[i], _Digits);
    }

    return SL;
}

// Find SL using a border channel - the low of the first bar with major part below upper line.
double FindUpperSLViaChannel()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double SL = -1;

    // Easy stop-loss via a separate horizontal line when using trendline trading.
    if (OpenOnCloseAboveBelowTrendline)
    {
        if (ObjectFind(0, SLLine) < 0) return -1;
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE, 0), _Digits);
    }

    for (int i = 0; i < Bars(_Symbol, _Period); i++)
    {
        // Get the upper of main and auxiliary lines
        double Border = MathMax(ObjectGetValueByTime(0, BorderChannel, Time[i], 0), ObjectGetValueByTime(0, BorderChannel, Time[i], 1));

        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next  bar's Low should be lower or equal to that of the first bar.
        if ((Border - Low[i] > High[i] - Border) && ((UpperEntry - Border < Border - Low[i]) || (i != 0)) && (Low[i] <= Low[0])) return NormalizeDouble(Low[i], _Digits);
    }

    return SL;
}

// Find SL using a border channel - the high of the first bar with major part above upper line.
double FindLowerSLViaChannel()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double SL = -1;

    // Easy stop-loss via a separate horizontal line when using trendline trading.
    if (OpenOnCloseAboveBelowTrendline)
    {
        if (ObjectFind(0, SLLine) < 0) return -1;
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE, 0), _Digits);
    }

    for (int i = 0; i < Bars(_Symbol, _Period); i++)
    {
        // Get the lower of main and auxiliary lines
        double Border = MathMin(ObjectGetValueByTime(0, BorderChannel, Time[i], 0), ObjectGetValueByTime(0, BorderChannel, Time[i], 1));

        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next  bar's High should be higher or equal to that of the first bar.
        if ((High[i] - Border > Border - Low[i]) && ((Border - LowerEntry < High[i] - Border) || (i != 0)) && (High[i] >= High[0])) return NormalizeDouble(High[i], _Digits);
    }

    return SL;
}

// Find entry point using the entry channel.
double FindUpperEntryViaChannel()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double Entry = -1;

    // Get the upper of main and auxiliary lines
    Entry = MathMax(ObjectGetValueByTime(0, EntryChannel, Time[0], 0), ObjectGetValueByTime(0, EntryChannel, Time[0], 1));

    return NormalizeDouble(Entry, _Digits);
}

// Find entry point using the entry channel.
double FindLowerEntryViaChannel()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double Entry = -1;

    // Get the lower of main and auxiliary lines
    Entry = MathMin(ObjectGetValueByTime(0, EntryChannel, Time[0], 0), ObjectGetValueByTime(0, EntryChannel, Time[0], 1));

    return NormalizeDouble(Entry, _Digits);
}

// Find TP using the TP channel.
double FindUpperTPViaChannel()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double TP = -1;

    // Get the upper of main and auxiliary lines.
    TP = MathMax(ObjectGetValueByTime(0, TPChannel, Time[0], 0), ObjectGetValueByTime(0, TPChannel, Time[0], 1));

    return NormalizeDouble(TP, _Digits);
}

// Find TP using the TP channel.
double FindLowerTPViaChannel()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double TP = -1;

    // Get the lower of main and auxiliary lines.
    TP = MathMin(ObjectGetValueByTime(0, TPChannel, Time[0], 0), ObjectGetValueByTime(0, TPChannel, Time[0], 1));

    return NormalizeDouble(TP, _Digits);
}

void AdjustOrders()
{
    AdjustObjects(); // Rename objects if pending orders got executed.
    AdjustUpperAndLowerOrders();
}

// Sets flags according to found pending orders and positions.
void FindOrders()
{
    HaveBuyPending = false;
    HaveSellPending = false;
    HaveBuy = false;
    HaveSell = false;
    if (PositionSelect(_Symbol))
    {
        if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) HaveBuy = true;
        else HaveSell = true;
    }
    for (int i = 0; i < OrdersTotal(); i++)
    {
        OrderGetTicket(i);
        if (((OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP) || (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT)) && (OrderGetString(ORDER_SYMBOL) == _Symbol) && (OrderGetInteger(ORDER_MAGIC) == Magic))
        {
            HaveBuyPending = true;
            UpperTicket = OrderGetTicket(i);
        }
        else if (((OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_STOP) || (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_LIMIT)) && (OrderGetString(ORDER_SYMBOL) == _Symbol) && (OrderGetInteger(ORDER_MAGIC) == Magic))
        {
            HaveSellPending = true;
            LowerTicket = OrderGetTicket(i);
        }
    }
}

// Renaming objects prevents new position opening.
void AdjustObjects()
{
    if (((HaveBuy) && (!HaveBuyPending)))
    {
        RenameObject(UpperBorderLine);
        RenameObject(UpperEntryLine);
        RenameObject(EntryChannel);
        if (OneCancelsOther)
        {
            RenameObject(LowerBorderLine);
            RenameObject(LowerEntryLine);
            RenameObject(BorderChannel);
        }
    }
    if (((HaveSell) && (!HaveSellPending)))
    {
        RenameObject(LowerBorderLine);
        RenameObject(LowerEntryLine);
        RenameObject(EntryChannel);
        if (OneCancelsOther)
        {
            RenameObject(UpperBorderLine);
            RenameObject(UpperEntryLine);
            RenameObject(BorderChannel);
        }
    }
}

void RenameObject(string Object)
{
    if (ObjectFind(0, Object) > -1) // If exists.
    {
        Print("Renaming ", Object, ".");
        ObjectSetString(0, Object, OBJPROP_NAME, Object + IntegerToString(Magic));
    }
}

// The main trading procedure. Sends, Modifies and Deletes orders.
void AdjustUpperAndLowerOrders()
{
    double NewVolume;
    int last_error;
    datetime expiration;
    ENUM_ORDER_TYPE_TIME type_time;
    ENUM_ORDER_TYPE order_type;
    string order_type_string;

    if ((!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) || (!TerminalInfoInteger(TERMINAL_CONNECTED)) || (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL))
    {
        if (!TDisabled) Output("Trading disabled or disconnected.");
        TDisabled = true;
        return;
    }
    else if (TDisabled)
    {
        Output("Trading is no longer disabled or disconnected.");
        TDisabled = false;
    }

    double StopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    double FreezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
    double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    if (OpenOnCloseAboveBelowTrendline) // Simple case.
    {
        double BorderLevel;
        if ((LowerTP > 0) && (!HaveSell) && (UseLower)) // SELL.
        {
            if (ObjectFind(0, LowerBorderLine) >= 0) // Line.
            {
                BorderLevel = NormalizeDouble(ObjectGetValueByTime(ChartID(), LowerBorderLine, Time[1]), _Digits);
            }
            else // Channel
            {
                BorderLevel = MathMin(ObjectGetValueByTime(0, BorderChannel, Time[1], 0), ObjectGetValueByTime(0, BorderChannel, Time[1], 1));
            }
            BorderLevel = NormalizeDouble(MathRound(BorderLevel / TickSize) * TickSize, _Digits);

            // Previous candle close significantly lower than the border line.
            if (BorderLevel - Close[1] >= SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * _Point * ThresholdSpreads)
            {
                NewVolume = GetPositionSize(Bid, LowerSL, ORDER_TYPE_SELL);
                LowerTicket = ExecuteMarketOrder(ORDER_TYPE_SELL, NewVolume, Bid, LowerSL, LowerTP);
            }
        }
        else if ((UpperTP > 0) && (!HaveBuy) && (UseUpper)) // BUY.
        {
            if (ObjectFind(0, UpperBorderLine) >= 0) // Line.
            {
                BorderLevel = NormalizeDouble(ObjectGetValueByTime(ChartID(), UpperBorderLine, Time[1]), _Digits);
            }
            else // Channel
            {
                BorderLevel = MathMax(ObjectGetValueByTime(0, BorderChannel, Time[1], 0), ObjectGetValueByTime(0, BorderChannel, Time[1], 1));
            }
            BorderLevel = NormalizeDouble(MathRound(BorderLevel / TickSize) * TickSize, _Digits);

            // Previous candle close significantly higher than the border line.
            if (Close[1] - BorderLevel >= SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * _Point * ThresholdSpreads)
            {

                NewVolume = GetPositionSize(Ask, UpperSL, ORDER_TYPE_BUY);
                UpperTicket = ExecuteMarketOrder(ORDER_TYPE_BUY, NewVolume, Ask, UpperSL, UpperTP);
            }
        }
        return;
    }
    
    // Have open position.
    if (PositionSelect(_Symbol))
    {
        // PostEntrySLAdjustment - a procedure to correct SL if breakout candle become too long and no longer qualifies for SL rule.
        if ((PositionGetInteger(POSITION_TIME) > Time[1]) && (PositionGetInteger(POSITION_TIME) < Time[0]) && (PostEntrySLAdjustment) && (PostBuySLAdjustmentDone == false))
        {
            double SL = AdjustPostBuySL();
            if (SL != -1)
            {
                // Avoid frozen context. In all modification cases.
                if ((FreezeLevel != 0) && (MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - Ask) <= FreezeLevel))
                {
                    Output("Skipping Modify Buy Stop SL because open price is too close to Ask. FreezeLevel = " + DoubleToString(FreezeLevel, _Digits) + " OpenPrice = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " Ask = " + DoubleToString(Ask, _Digits));
                }
                else
                {
                    if (NormalizeDouble(SL, _Digits) == NormalizeDouble(PositionGetDouble(POSITION_SL), _Digits)) PostBuySLAdjustmentDone = true;
                    else
                    {
                        if (!Trade.PositionModify(_Symbol, SL, PositionGetDouble(POSITION_TP)))
                        {
                            last_error = GetLastError();
                            Output("Error Modifying Buy SL: " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                            Output("FROM: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits) + " SL = " + DoubleToString(PositionGetDouble(POSITION_SL), _Digits) + " -> TO: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " SL = " + DoubleToString(SL, 8) + " Ask = " + DoubleToString(Ask, _Digits));
                        }
                        else PostBuySLAdjustmentDone = true;
                    }
                }
            }
        }
        // Adjust TP only.
        if ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) && (!DisableBuyOrders))
        {
            // Avoid frozen context. In all modification cases.
            if ((FreezeLevel != 0) && (MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - Ask) <= FreezeLevel))
            {
                Output("Skipping Modify Buy TP because open price is too close to Ask. FreezeLevel = " + DoubleToString(FreezeLevel, _Digits) + " OpenPrice = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " Ask = " + DoubleToString(Ask, _Digits));
            }
            else if ((NormalizeDouble(PositionGetDouble(POSITION_TP), _Digits) != NormalizeDouble(UpperTP, _Digits)) && (UpperTP != 0))
            {
                if (!Trade.PositionModify(_Symbol, PositionGetDouble(POSITION_SL), UpperTP))
                {
                    last_error = GetLastError();
                    Output("Error Modifying Buy TP: " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("FROM: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits) + " TP = " + DoubleToString(PositionGetDouble(POSITION_TP), _Digits) + " -> TO: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " TP = " + DoubleToString(UpperTP, 8) + " Ask = " + DoubleToString(Ask, _Digits));
                }
            }
        }
        else if ((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) && (!DisableSellOrders))
        {
            // PostEntrySLAdjustment - a procedure to correct SL if breakout candle become too long and no longer qualifies for SL rule.
            if ((PositionGetInteger(POSITION_TIME) > Time[1]) && (PositionGetInteger(POSITION_TIME) < Time[0]) && (PostEntrySLAdjustment) && (PostSellSLAdjustmentDone == false))
            {
                double SL = AdjustPostSellSL();
                if (SL != -1)
                {
                    // Avoid frozen context. In all modification cases.
                    if ((FreezeLevel != 0) && (MathAbs(Bid - PositionGetDouble(POSITION_PRICE_OPEN)) <= FreezeLevel))
                    {
                        Output("Skipping Modify Sell Stop SL because open price is too close to Bid. FreezeLevel = " + DoubleToString(FreezeLevel, _Digits) + " OpenPrice = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " Bid = " + DoubleToString(Bid, _Digits));
                    }
                    else
                    {
                        if (NormalizeDouble(SL, _Digits) == NormalizeDouble(PositionGetDouble(POSITION_SL), _Digits)) PostSellSLAdjustmentDone = true;
                        else
                        {
                            if (!Trade.PositionModify(_Symbol, SL, PositionGetDouble(POSITION_TP)))
                            {
                                last_error = GetLastError();
                                Output("Error Modifying Sell SL: " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                                Output("FROM: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits) + " SL = " + DoubleToString(PositionGetDouble(POSITION_SL), _Digits) + " -> TO: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " SL = " + DoubleToString(SL, 8) + " Bid = " + DoubleToString(Bid, _Digits));
                            }
                            else PostSellSLAdjustmentDone = true;
                        }
                    }
                }
            }
            // Avoid frozen context. In all modification cases.
            if ((FreezeLevel != 0) && (MathAbs(Bid - PositionGetDouble(POSITION_PRICE_OPEN)) <= FreezeLevel))
            {
                Output("Skipping Modify Sell TP because open price is too close to Bid. FreezeLevel = " + DoubleToString(FreezeLevel, _Digits) + " OpenPrice = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " Bid = " + DoubleToString(Bid, _Digits));
            }
            else if ((NormalizeDouble(PositionGetDouble(POSITION_TP), _Digits) != LowerTP) && (NormalizeDouble(LowerTP, _Digits) != 0))
            {
                if (!Trade.PositionModify(_Symbol, PositionGetDouble(POSITION_SL), LowerTP))
                {
                    last_error = GetLastError();
                    Output("Error Modifying Sell TP: " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("FROM: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits) + " TP = " + DoubleToString(PositionGetDouble(POSITION_TP), _Digits) + " -> TO: Entry = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 8) + " TP = " + DoubleToString(LowerTP, 8) + " Bid = " + DoubleToString(Bid, _Digits));
                }
            }
        }
    }

    for (int i = 0; i < OrdersTotal(); i++)
    {
        ulong ticket = OrderGetTicket(i);
        // Refresh rates.
        Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        // BUY.
        if (((OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP) || (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT)) && (OrderGetString(ORDER_SYMBOL) == _Symbol) && (OrderGetInteger(ORDER_MAGIC) == Magic) && (!DisableBuyOrders))
        {
            // Current price is below Sell entry - pending Sell Limit will be used instead of two stop orders.
            if ((LowerEntry - Bid > StopLevel) && (UseLower)) continue;

            NewVolume = GetPositionSize(UpperEntry, UpperSL, ORDER_TYPE_BUY);
            // Delete existing pending order
            if ((HaveBuy) || ((HaveSell) && (OneCancelsOther)) || (!UseUpper)) Trade.OrderDelete(ticket);
            // If volume needs to be updated - delete and recreate order with new volume. Also check if EA will be able to create new pending order at current price.
            else if ((UpdatePendingVolume) && (OrderGetDouble(ORDER_VOLUME_CURRENT) != NewVolume))
            {
                if ((UpperEntry - Ask > StopLevel) || (Ask - UpperEntry > StopLevel)) // Order can be re-created
                {
                    Trade.OrderDelete(ticket);
                }
                else continue;
                // Ask could change after deletion, check if there is still no error 130 present.
                Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                if (UpperEntry - Ask > StopLevel) // Current price below entry
                {
                    order_type = ORDER_TYPE_BUY_STOP;
                    order_type_string = "Stop";
                }
                else if (Ask - UpperEntry > StopLevel) // Current price above entry
                {
                    order_type = ORDER_TYPE_BUY_LIMIT;
                    order_type_string = "Limit";
                }
                else continue;
                if (ExpirationEnabled)
                {
                    type_time = ORDER_TIME_SPECIFIED;
                    // Set expiration to the end of the current bar.
                    expiration = Time[0] + GetSecondsPerBar();
                    // 2 minutes seem to be the actual minimum expiration time.
                    if (expiration - TimeCurrent() < 121) expiration = TimeCurrent() + 121;
                }
                else
                {
                    expiration = 0;
                    type_time = ORDER_TIME_GTC;
                }
                if (!Trade.OrderOpen(_Symbol, order_type, NewVolume, 0, UpperEntry, UpperSL, UpperTP, type_time, expiration, "ChartPatternHelper"))
                {
                    last_error = GetLastError();
                    Output("StopLevel = " + DoubleToString(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToString(FreezeLevel, 8));
                    Output("Error Recreating Buy " + order_type_string + ": " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("Volume = " + DoubleToString(NewVolume, LotStep_digits) + " Entry = " + DoubleToString(UpperEntry, _Digits) + " SL = " + DoubleToString(UpperSL, _Digits) + " TP = " + DoubleToString(UpperTP, _Digits) + " Bid/Ask = " + DoubleToString(Bid, _Digits) + "/" + DoubleToString(Ask, _Digits) + " Exp: " + TimeToString(expiration, TIME_DATE | TIME_SECONDS));
                }
                else
                {
                    UpperTicket = Trade.ResultOrder();
                }
                continue;
            }
            // Otherwise, just update what needs to be updated.
            else if ((NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) != NormalizeDouble(UpperEntry, _Digits)) || (NormalizeDouble(OrderGetDouble(ORDER_SL), _Digits) != NormalizeDouble(UpperSL, _Digits)) || (NormalizeDouble(OrderGetDouble(ORDER_TP), _Digits) != NormalizeDouble(UpperTP, _Digits)))
            {
                // Avoid error 130 based on entry.
                if (UpperEntry - Ask > StopLevel) // Current price below entry
                {
                    order_type_string = "Stop";
                }
                else if (Ask - UpperEntry > StopLevel) // Current price above entry
                {
                    order_type_string = "Limit";
                }
                else if (NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) != NormalizeDouble(LowerEntry, _Digits)) continue;
                // Avoid error 130 based on stop-loss.
                if (UpperEntry - UpperSL <= StopLevel)
                {
                    Output("Skipping Modify Buy " + order_type_string + " because stop-loss is too close to entry. StopLevel = " + DoubleToString(StopLevel, _Digits) + " Entry = " + DoubleToString(UpperEntry, _Digits) + " SL = " + DoubleToString(UpperSL, _Digits));
                    continue;
                }
                // Avoid frozen context. In all modification cases.
                if ((FreezeLevel != 0) && (MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - Ask) <= FreezeLevel))
                {
                    Output("Skipping Modify Buy " + order_type_string + " because open price is too close to Ask. FreezeLevel = " + DoubleToString(FreezeLevel, _Digits) + " OpenPrice = " + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) + " Ask = " + DoubleToString(Ask, _Digits));
                    continue;
                }
                double prevOrderOpenPrice = OrderGetDouble(ORDER_PRICE_OPEN);
                double prevOrderStopLoss = OrderGetDouble(ORDER_SL);
                double prevOrderTakeProfit = OrderGetDouble(ORDER_TP);
                type_time = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
                expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
                if (expiration == TimeCurrent()) continue; // Skip modification of orders that are about to expire
                if (!Trade.OrderModify(ticket, UpperEntry, UpperSL, UpperTP, type_time, expiration))
                {
                    last_error = GetLastError();
                    Output("type_time = " + EnumToString(type_time));
                    Output("StopLevel = " + DoubleToString(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToString(FreezeLevel, 8));
                    Output("Error Modifying Buy " + order_type_string + ": " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("FROM: Entry = " + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) + " SL = " + DoubleToString(OrderGetDouble(ORDER_SL), _Digits) + " TP = " + DoubleToString(OrderGetDouble(ORDER_TP), _Digits) + " -> TO: Entry = " + DoubleToString(UpperEntry, 8) + " SL = " + DoubleToString(UpperSL, 8) + " TP = " + DoubleToString(UpperTP, 8) + " Bid/Ask = " + DoubleToString(Bid, _Digits) + "/" + DoubleToString(Ask, _Digits) + " OrderTicket = " + IntegerToString(ticket) + " OrderExpiration = " + TimeToString(OrderGetInteger(ORDER_TIME_EXPIRATION), TIME_DATE | TIME_SECONDS) + " -> " + TimeToString(expiration, TIME_DATE | TIME_SECONDS));
                }
            }
        }
        // SELL.
        else if (((OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_STOP) || (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_LIMIT)) && (OrderGetString(ORDER_SYMBOL) == _Symbol) && (OrderGetInteger(ORDER_MAGIC) == Magic) && (!DisableSellOrders))
        {
            // Current price is above Buy entry - pending Buy Limit will be used instead of two stop orders.
            if ((Ask - UpperEntry > StopLevel) && (UseUpper)) continue;

            NewVolume = GetPositionSize(LowerEntry, LowerSL, ORDER_TYPE_BUY);
            // Delete existing pending order.
            if (((HaveBuy) && (OneCancelsOther)) || (HaveSell) || (!UseLower)) Trade.OrderDelete(ticket);
            // If volume needs to be updated - delete and recreate order with new volume. Also check if EA will be able to create new pending order at current price.
            else if ((UpdatePendingVolume) && (OrderGetDouble(ORDER_VOLUME_CURRENT) != NewVolume) && (Bid - LowerEntry > StopLevel))
            {
                if ((Bid - LowerEntry > StopLevel) || (LowerEntry - Bid > StopLevel)) // Order can be re-created
                {
                    Trade.OrderDelete(ticket);
                }
                // Bid could change after deletion, check if there is still no error 130 present.
                Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if (Bid - LowerEntry > StopLevel) // Current price above entry.
                {
                    order_type = ORDER_TYPE_SELL_STOP;
                    order_type_string = "Stop";
                }
                else if (LowerEntry - Bid > StopLevel) // Current price below entry.
                {
                    order_type = ORDER_TYPE_SELL_LIMIT;
                    order_type_string = "Limit";
                }
                else continue;
                if (ExpirationEnabled)
                {
                    type_time = ORDER_TIME_SPECIFIED;
                    // Set expiration to the end of the current bar.
                    expiration = Time[0] + GetSecondsPerBar();
                    // 2 minutes seem to be the actual minimum expiration time.
                    if (expiration - TimeCurrent() < 121) expiration = TimeCurrent() + 121;
                }
                else
                {
                    expiration = 0;
                    type_time = ORDER_TIME_GTC;
                }
                if (!Trade.OrderOpen(_Symbol, order_type, NewVolume, 0, LowerEntry, LowerSL, LowerTP, type_time, expiration, "ChartPatternHelper"))
                {
                    last_error = GetLastError();
                    Output("StopLevel = " + DoubleToString(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToString(FreezeLevel, 8));
                    Output("Error Recreating Sell " + order_type_string + ": " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("Volume = " + DoubleToString(NewVolume, LotStep_digits) + " Entry = " + DoubleToString(LowerEntry, _Digits) + " SL = " + DoubleToString(LowerSL, _Digits) + " TP = " + DoubleToString(LowerTP, _Digits) + " Bid/Ask = " + DoubleToString(Bid, _Digits) + "/" + DoubleToString(Ask, _Digits) + " Exp: " + TimeToString(expiration, TIME_DATE | TIME_SECONDS));
                }
                else
                {
                    LowerTicket = Trade.ResultOrder();
                }
                continue;
            }
            // Otherwise just update what needs to be updated
            else if ((NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) != NormalizeDouble(LowerEntry, _Digits)) || (NormalizeDouble(OrderGetDouble(ORDER_SL), _Digits) != NormalizeDouble(LowerSL, _Digits)) || (NormalizeDouble(OrderGetDouble(ORDER_TP), _Digits) != NormalizeDouble(LowerTP, _Digits)))
            {
                // Avoid error 130 based on entry.
                if (Bid - LowerEntry > StopLevel) // Current price above entry
                {
                    order_type_string = "Stop";
                }
                else if (LowerEntry - Bid > StopLevel) // Current price below entry
                {
                    order_type_string = "Limit";
                }
                else if (NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) != NormalizeDouble(LowerEntry, _Digits)) continue;
                // Avoid error 130 based on stop-loss.
                if (LowerSL - LowerEntry <= StopLevel)
                {
                    Output("Skipping Modify Sell " + order_type_string + " because stop-loss is too close to entry. StopLevel = " + DoubleToString(StopLevel, _Digits) + " Entry = " + DoubleToString(LowerEntry, _Digits) + " SL = " + DoubleToString(LowerSL, _Digits));
                    continue;
                }
                // Avoid frozen context. In all modification cases.
                if ((FreezeLevel != 0) && (MathAbs(Bid - OrderGetDouble(ORDER_PRICE_OPEN)) <= FreezeLevel))
                {
                    Output("Skipping Modify Sell " + order_type_string + " because open price is too close to Bid. FreezeLevel = " + DoubleToString(FreezeLevel, _Digits) + " OpenPrice = " + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) + " Bid = " + DoubleToString(Bid, _Digits));
                    continue;
                }
                double prevOrderOpenPrice = OrderGetDouble(ORDER_PRICE_OPEN);
                double prevOrderStopLoss = OrderGetDouble(ORDER_SL);
                double prevOrderTakeProfit = OrderGetDouble(ORDER_TP);
                type_time = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
                expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
                if (expiration == TimeCurrent()) continue; // Skip modification of orders that are about to expire
                if (!Trade.OrderModify(ticket, LowerEntry, LowerSL, LowerTP, type_time, expiration))
                {
                    last_error = GetLastError();
                    Output("type_time = " + EnumToString(type_time));
                    Output("StopLevel = " + DoubleToString(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToString(FreezeLevel, 8));
                    Output("Error Modifying Sell " + order_type_string + ": " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("FROM: Entry = " + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) + " SL = " + DoubleToString(OrderGetDouble(ORDER_SL), _Digits) + " TP = " + DoubleToString(OrderGetDouble(ORDER_TP), _Digits) + " -> TO: Entry = " + DoubleToString(LowerEntry, 8) + " SL = " + DoubleToString(LowerSL, 8) + " TP = " + DoubleToString(LowerTP, 8) + " Bid/Ask = " + DoubleToString(Bid, _Digits) + "/" + DoubleToString(Ask, _Digits) + " OrderTicket = " + IntegerToString(ticket) + " OrderExpiration = " + TimeToString(OrderGetInteger(ORDER_TIME_EXPIRATION), TIME_DATE | TIME_SECONDS) + " -> " + TimeToString(expiration, TIME_DATE | TIME_SECONDS));
                }
            }
        }
    }

    // BUY.
    // If we do not already have Long position or Long pending order and if we can enter Long
    // and the current price is not below the Sell entry (in that case, only pending Sell Limit order will be used.)
    if ((!HaveBuy) && (!HaveBuyPending) && (UseUpper) && ((LowerEntry - Bid <= StopLevel) || (!UseLower)))
    {
        // Avoid error 130 based on stop-loss.
        if (UpperEntry - UpperSL <= StopLevel)
        {
            Output("Skipping Send Pending Buy because stop-loss is too close to entry. StopLevel = " + DoubleToString(StopLevel, _Digits) + " Entry = " + DoubleToString(UpperEntry, _Digits) + " SL = " + DoubleToString(UpperSL, _Digits));
        }
        else
        {
            if (UpperEntry - Ask > StopLevel) // Current price below entry.
            {
                order_type = ORDER_TYPE_BUY_STOP;
                order_type_string = "Stop";
            }
            else if (Ask - UpperEntry > StopLevel) // Current price above entry.
            {
                order_type = ORDER_TYPE_BUY_LIMIT;
                order_type_string = "Limit";
            }
            else
            {
                order_type = NULL;
                Output("Skipping Send Pending Buy because entry is too close to Ask. StopLevel = " + DoubleToString(StopLevel, _Digits) + " Entry = " + DoubleToString(UpperEntry, _Digits) + " Ask = " + DoubleToString(Ask, _Digits));
            }
            if (order_type != NULL)
            {
                if (ExpirationEnabled)
                {
                    type_time = ORDER_TIME_SPECIFIED;
                    // Set expiration to the end of the current bar.
                    expiration = Time[0] + GetSecondsPerBar();
                    // 2 minutes seem to be the actual minimum expiration time.
                    if (expiration - TimeCurrent() < 121) expiration = TimeCurrent() + 121;
                }
                else
                {
                    expiration = 0;
                    type_time = ORDER_TIME_GTC;
                }
                NewVolume = GetPositionSize(UpperEntry, UpperSL, ORDER_TYPE_BUY);
                if (!Trade.OrderOpen(_Symbol, order_type, NewVolume, 0, UpperEntry, UpperSL, UpperTP, type_time, expiration, "ChartPatternHelper"))
                {
                    last_error = GetLastError();
                    Output("type_time = " + IntegerToString(type_time));
                    Output("StopLevel = " + DoubleToString(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToString(FreezeLevel, 8));
                    Output("Error Sending Buy " + order_type_string + ": " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("Volume = " + DoubleToString(NewVolume, LotStep_digits) + " Entry = " + DoubleToString(UpperEntry, _Digits) + " SL = " + DoubleToString(UpperSL, _Digits) + " TP = " + DoubleToString(UpperTP, _Digits) + " Bid/Ask = " + DoubleToString(Bid, _Digits) + "/" + DoubleToString(Ask, _Digits) + " Exp: " + TimeToString(expiration, TIME_DATE | TIME_SECONDS));
                }
                else
                {
                    UpperTicket = Trade.ResultOrder();
                }
            }
        }
    }
    // SELL.
    // If we do not already have Short position or Short pending order and if we can enter Short
    // and the current price is not above the Buy entry (in that case, only pending Buy  Limit order will be used.)
    if ((!HaveSell) && (!HaveSellPending) && (UseLower) && ((Ask - UpperEntry <= StopLevel) || (!UseUpper)))
    {
        // Avoid error 130 based on stop-loss.
        if (LowerSL - LowerEntry <= StopLevel)
        {
            Output("Skipping Send Pending Sell because stop-loss is too close to entry. StopLevel = " + DoubleToString(StopLevel, _Digits) + " Entry = " + DoubleToString(LowerEntry, _Digits) + " SL = " + DoubleToString(LowerSL, _Digits));
        }
        else
        {
            if (Bid - LowerEntry > StopLevel) // Current price above entry
            {
                order_type = ORDER_TYPE_SELL_STOP;
                order_type_string = "Stop";
            }
            else if (LowerEntry - Bid > StopLevel) // Current price below entry
            {
                order_type = ORDER_TYPE_SELL_LIMIT;
                order_type_string = "Limit";
            }
            else
            {
                order_type = NULL;
                Output("Skipping Send Pending Sell because entry is too close to Bid. StopLevel = " + DoubleToString(StopLevel, _Digits) + " Entry = " + DoubleToString(LowerEntry, _Digits) + " Bid = " + DoubleToString(Bid, _Digits));
            }
            if (order_type != NULL)
            {
                if (ExpirationEnabled)
                {
                    type_time = ORDER_TIME_SPECIFIED;
                    // Set expiration to the end of the current bar.
                    expiration = Time[0] + GetSecondsPerBar();
                    // 2 minutes seem to be the actual minimum expiration time.
                    if (expiration - TimeCurrent() < 121) expiration = TimeCurrent() + 121;
                }
                else
                {
                    expiration = 0;
                    type_time = ORDER_TIME_GTC;
                }
                NewVolume = GetPositionSize(LowerEntry, LowerSL, ORDER_TYPE_SELL);
                if (!Trade.OrderOpen(_Symbol, order_type, NewVolume, 0, LowerEntry, LowerSL, LowerTP, type_time, expiration, "ChartPatternHelper"))
                {
                    last_error = GetLastError();
                    Output("type_time = " + IntegerToString(type_time));
                    Output("StopLevel = " + DoubleToString(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToString(FreezeLevel, 8));
                    Output("Error Sending Sell " + order_type_string + ": " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
                    Output("Volume = " + DoubleToString(NewVolume, LotStep_digits) + " Entry = " + DoubleToString(LowerEntry, _Digits) + " SL = " + DoubleToString(LowerSL, _Digits) + " TP = " + DoubleToString(LowerTP, _Digits) + " Bid/Ask = " + DoubleToString(Bid, _Digits) + "/" + DoubleToString(Ask, _Digits) + " Exp: " + TimeToString(expiration, TIME_DATE | TIME_SECONDS));
                }
                else
                {
                    LowerTicket = Trade.ResultOrder();
                }
            }
        }
    }
}

void PrepareTimeseries()
{
    if (CopyTime(_Symbol, _Period, 0, Bars(_Symbol, _Period), Time) != Bars(_Symbol, _Period))
    {
        Print("Cannot copy Time array.");
        return;
    }
    ArraySetAsSeries(Time, true);
    if (CopyHigh(_Symbol, _Period, 0, Bars(_Symbol, _Period), High) != Bars(_Symbol, _Period))
    {
        Print("Cannot copy High array.");
        return;
    }
    ArraySetAsSeries(High, true);
    if (CopyLow(_Symbol, _Period, 0, Bars(_Symbol, _Period), Low) != Bars(_Symbol, _Period))
    {
        Print("Cannot copy Low array.");
        return;
    }
    ArraySetAsSeries(Low, true);
    if (CopyClose(_Symbol, _Period, 0, Bars(_Symbol, _Period), Close) != Bars(_Symbol, _Period))
    {
        Print("Cannot copy Close array.");
        return;
    }
    ArraySetAsSeries(Close, true);
}

void SetComment(string c)
{
    if (!Silent) Comment(c);
}

//+------------------------------------------------------------------+
//| Calculates symbol leverage value based on required margin        |
//| and current rates.                                               |
//+------------------------------------------------------------------+
double CalculateUnitCost()
{
    double UnitCost;
    // CFD.
    if (((CalcMode == SYMBOL_CALC_MODE_CFD) || (CalcMode == SYMBOL_CALC_MODE_CFDINDEX) || (CalcMode == SYMBOL_CALC_MODE_CFDLEVERAGE)))
        UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE) * SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
    // With Forex and futures instruments, tick value already equals 1 unit cost.
    else UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE_LOSS);
    
    return UnitCost;
}

//+-----------------------------------------------------------------------------------+
//| Calculates necessary adjustments for cases when GivenCurrency != AccountCurrency. |
//+-----------------------------------------------------------------------------------+
double CalculateAdjustment()
{
    if (ReferencePair == NULL)
    {
        ReferencePair = GetSymbolByCurrencies(ProfitCurrency, AccountCurrency);
        ReferenceSymbolMode = true;
        // Failed.
        if (ReferencePair == NULL)
        {
            // Reversing currencies.
            ReferencePair = GetSymbolByCurrencies(AccountCurrency, ProfitCurrency);
            ReferenceSymbolMode = false;
        }
    }
    if (ReferencePair == NULL)
    {
        Print("Error! Cannot detect proper currency pair for adjustment calculation: ", ProfitCurrency, ", ", AccountCurrency, ".");
        ReferencePair = Symbol();
        return 1;
    }
    MqlTick tick;
    SymbolInfoTick(ReferencePair, tick);
    return GetCurrencyCorrectionCoefficient(tick);
}

//+---------------------------------------------------------------------------+
//| Returns a currency pair with specified base currency and profit currency. |
//+---------------------------------------------------------------------------+
string GetSymbolByCurrencies(string base_currency, string profit_currency)
{
    // Cycle through all symbols.
    for (int s = 0; s < SymbolsTotal(false); s++)
    {
        // Get symbol name by number.
        string symbolname = SymbolName(s, false);

        // Skip non-Forex pairs.
        if ((SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX) && (SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)) continue;

        // Get its base currency.
        string b_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_BASE);

        // Get its profit currency.
        string p_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_PROFIT);

        // If the currency pair matches both currencies, select it in Market Watch and return its name.
        if ((b_cur == base_currency) && (p_cur == profit_currency))
        {
            // Select if necessary.
            if (!(bool)SymbolInfoInteger(symbolname, SYMBOL_SELECT)) SymbolSelect(symbolname, true);

            return symbolname;
        }
    }
    return NULL;
}

//+------------------------------------------------------------------+
//| Get correction coefficient based on currency, trade direction,   |
//| and current prices.                                              |
//+------------------------------------------------------------------+
double GetCurrencyCorrectionCoefficient(MqlTick &tick)
{
    if ((tick.ask == 0) || (tick.bid == 0)) return -1; // Data is not yet ready.
    // Reverse quote.
    if (ReferenceSymbolMode)
    {
        // Using Buy price for reverse quote.
        return tick.ask;
    }
    // Direct quote.
    else
    {
        // Using Sell price for direct quote.
        return (1 / tick.bid);
    }
}

// Taken from the PositionSizeCalculator indicator.
double GetPositionSize(double Entry, double StopLoss, ENUM_ORDER_TYPE dir)
{
    double Size, RiskMoney, PositionSize = 0;

    double SL = MathAbs(Entry - StopLoss);

    AccountCurrency = AccountInfoString(ACCOUNT_CURRENCY);

    // A rough patch for cases when account currency is set as RUR instead of RUB.
    if (AccountCurrency == "RUR") AccountCurrency = "RUB";

    ProfitCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_PROFIT);
    BaseCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_BASE);
    CalcMode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_CALC_MODE);
    double LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    if (!CalculatePositionSize) return(FixedPositionSize);

    // If could not find account currency, probably not connected.
    if (AccountInfoString(ACCOUNT_CURRENCY) == "") return -1;

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountInfoDouble(ACCOUNT_EQUITY);
    }
    else
    {
        Size = AccountInfoDouble(ACCOUNT_BALANCE);
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    double UnitCost = CalculateUnitCost();

    // If profit currency is different from account currency and Symbol is not a Forex pair (CFD, futures, and so on).
    if ((ProfitCurrency != AccountCurrency) && (CalcMode != SYMBOL_CALC_MODE_FOREX) && (CalcMode != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE))
    {
        double CCC = CalculateAdjustment(); // Valid only for loss calculation.
        // Adjust the unit cost.
        UnitCost *= CCC;
    }

    // If account currency == pair's base currency, adjust UnitCost to future rate (SL). Works only for Forex pairs.
    if ((AccountCurrency == BaseCurrency) && ((CalcMode == SYMBOL_CALC_MODE_FOREX) || (CalcMode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)))
    {
        double current_rate = 1, future_rate = StopLoss;
        if (dir == ORDER_TYPE_BUY)
        {
            current_rate = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
        else if (dir == ORDER_TYPE_SELL)
        {
            current_rate = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
        UnitCost *= (current_rate / future_rate);
    }

    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if ((SL != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (SL * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) PositionSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    else if (PositionSize > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)) PositionSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double steps = PositionSize / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (MathFloor(steps) < steps) PositionSize = MathFloor(steps) * SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    return PositionSize;
}

// Prints and writes to a file error info and context data.
void Output(string s)
{
    Print(s);
    if (!ErrorLogging) return;
    int file = FileOpen(filename, FILE_CSV | FILE_READ | FILE_WRITE);
    if (file == INVALID_HANDLE) Print("Failed to create an error log file: ", GetLastError(), ".");
    else
    {
        FileSeek(file, 0, SEEK_END);
        s = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " - " + s;
        FileWrite(file, s);
        FileClose(file);
    }
}

// Taken from the PriceChangeCounter indicator.
int GetDaysInMonth(MqlDateTime &dt_struct)
{
    int month = dt_struct.mon;
    int year = dt_struct.year;

    if (month == 1) return 31;
    else if (month == 2)
    {
        // February - leap years
        if ((year % 4 == 0) && ((year % 100 != 0) || (year % 400 == 0))) return 29;
        else return 28;
    }
    else if (month == 3) return 31;
    else if (month == 4) return 30;
    else if (month == 5) return 31;
    else if (month == 6) return 30;
    else if (month == 7) return 31;
    else if (month == 8) return 31;
    else if (month == 9) return 30;
    else if (month == 10) return 31;
    else if (month == 11) return 30;
    else if (month == 12) return 31;

    return -1;
}

int GetSecondsPerBar()
{
    // If timeframe < MN - return already calculated value.
    if (Period() != PERIOD_MN1) return SecondsPerBar;
    // Otherwise, call functions to calculate number of days in current month.
    MqlDateTime dt_struct;
    TimeToStruct(Time[0], dt_struct);
    int days = GetDaysInMonth(dt_struct);
    if (days == -1) Alert("Could not detect number of days in a month.");
    return (days * 86400);
}

// Runs only one time to adjust SL to appropriate bar's Low if breakout bar's part outside the pattern turned out to be longer than the one inside.
// Works only if PostEntrySLAdjustment = true.
double AdjustPostBuySL()
{
    double SL = -1;
    string smagic = IntegerToString(Magic);
    double Border;

    // Border.
    if (ObjectFind(0, UpperBorderLine + smagic) > -1)
    {
        if ((ObjectGetInteger(0, UpperBorderLine + smagic, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, UpperBorderLine + smagic, OBJPROP_TYPE) != OBJ_TREND)) return SL;
        // Starting from 1 because it is new bar after breakout bar.
        for (int i = 1; i < Bars(_Symbol, _Period); i++)
        {
            if (ObjectGetInteger(0, UpperBorderLine + smagic, OBJPROP_TYPE) != OBJ_HLINE) Border = ObjectGetValueByTime(0, UpperBorderLine + smagic, Time[i], 0);
            else Border = ObjectGetDouble(0, UpperBorderLine + smagic, OBJPROP_PRICE, 0); // Horizontal line value.
            // Major part inside pattern but and SL not closer than breakout bar's SL.
            if ((Border - Low[i] > High[i] - Border) && (Low[i] <= Low[1])) return NormalizeDouble(Low[i], _Digits);
        }
    }
    else // Try to find a channel.
    {
        if (ObjectFind(0, BorderChannel + smagic) > -1)
        {
            if (ObjectGetInteger(0, BorderChannel + smagic, OBJPROP_TYPE) != OBJ_CHANNEL) return SL;
            for (int i = 1; i < Bars(_Symbol, _Period); i++)
            {
                // Get the upper of main and auxiliary lines.
                Border = MathMax(ObjectGetValueByTime(0, BorderChannel + smagic, Time[i], 0), ObjectGetValueByTime(0, BorderChannel + smagic, Time[i], 1));
                // Major part inside pattern but and SL not closer than breakout bar's SL.
                if ((Border - Low[i] > High[i] - Border) && (Low[i] <= Low[0])) return NormalizeDouble(Low[i], _Digits);
            }
        }
    }
    return SL;
}

// Runs only one time to adjust SL to appropriate bar's High if breakout bar's part outside the pattern turned out to be longer than the one inside.
// Works only if PostEntrySLAdjustment = true.
double AdjustPostSellSL()
{
    double SL = -1;
    string smagic = IntegerToString(Magic);
    double Border;

    // Border.
    if (ObjectFind(0, LowerBorderLine + smagic) > -1)
    {
        if ((ObjectGetInteger(0, LowerBorderLine + smagic, OBJPROP_TYPE) != OBJ_HLINE) && (ObjectGetInteger(0, LowerBorderLine + smagic, OBJPROP_TYPE) != OBJ_TREND)) return SL;
        // Starting from 1 because it is new bar after breakout bar.
        for (int i = 1; i < Bars(_Symbol, _Period); i++)
        {
            if (ObjectGetInteger(0, LowerBorderLine + smagic, OBJPROP_TYPE) != OBJ_HLINE) Border = ObjectGetValueByTime(0, LowerBorderLine + smagic, Time[i], 0);
            else Border = ObjectGetDouble(0, LowerBorderLine + smagic, OBJPROP_PRICE, 0); // Horizontal line value.
            // Major part inside pattern but and SL not closer than breakout bar's SL.
            if ((High[i] - Border > Border - Low[i]) && (High[i] >= High[0])) return NormalizeDouble(High[i], _Digits);
        }
    }
    else // Try to find a channel.
    {
        if (ObjectFind(0, BorderChannel + smagic) > -1)
        {
            if (ObjectGetInteger(0, BorderChannel + smagic, OBJPROP_TYPE) != OBJ_CHANNEL) return SL;
            for (int i = 1; i < Bars(_Symbol, _Period); i++)
            {
                // Get the lower of main and auxiliary lines.
                Border = MathMin(ObjectGetValueByTime(0, BorderChannel + smagic, Time[i], 0), ObjectGetValueByTime(0, BorderChannel + smagic, Time[i], 1));
                // Major part inside pattern but and SL not closer than breakout bar's SL.
                if ((High[i] - Border > Border - Low[i]) && (High[i] >= High[0])) return NormalizeDouble(High[i], _Digits);
            }
        }
    }
    return SL;
}

//+------------------------------------------------------------------+
//| Counts decimal places.                                           |
//+------------------------------------------------------------------+
int CountDecimalPlaces(double number)
{
    // 100 as maximum length of number.
    for (int i = 0; i < 100; i++)
    {
        double pwr = MathPow(10, i);
        if (MathRound(number * pwr) / pwr == number) return i;
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Execute a markte order (depends on symbol's trade execution mode.|
//+------------------------------------------------------------------+
ulong ExecuteMarketOrder(const ENUM_ORDER_TYPE order_type, const double volume, const double price, const double sl, const double tp)
{
    double order_sl = sl;
    double order_tp = tp;

    double StopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    double FreezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
    double LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    ENUM_SYMBOL_TRADE_EXECUTION Execution_Mode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_EXEMODE);
    
    // Market execution mode - preparation.
    if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET)
    {
        // No SL/TP allowed on instant orders.
        order_sl = 0;
        order_tp = 0;
    }

    if (!Trade.PositionOpen(Symbol(), order_type, volume, price, order_sl, order_tp, "Chart Pattern Helper"))
    {
        Output("Error sending order: " + Trade.ResultRetcodeDescription() + ".");
    }
    else
    {
        MqlTradeResult result;
        Trade.Result(result);
        if ((Trade.ResultRetcode() != 10008) && (Trade.ResultRetcode() != 10009) && (Trade.ResultRetcode() != 10010))
        {
            int last_error = GetLastError();
            Output("StopLevel = " + DoubleToString(StopLevel, 8));
            Output("FreezeLevel = " + DoubleToString(FreezeLevel, 8));
            Output("Error Sending Order " + EnumToString(order_type) + ": " + IntegerToString(last_error) + " (" + Trade.ResultRetcodeDescription() + ")");
            Output("Volume = " + DoubleToString(volume, LotStep_digits) + " Entry = " + DoubleToString(price, _Digits) + " SL = " + DoubleToString(order_sl, _Digits) + " TP = " + DoubleToString(order_tp, _Digits));
            return 0;
        }

        Output("Initial return code: " + Trade.ResultRetcodeDescription());

        ulong order = result.order;
        Output("Order ID: " + IntegerToString(order));

        ulong deal = result.deal;
        Output("Deal ID: " + IntegerToString(deal));

        // Market execution mode - application of SL/TP.
        if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET)
        {
            // Not all brokers return deal.
            if (deal != 0)
            {
                if (HistorySelect(TimeCurrent() - 60, TimeCurrent()))
                {
                    if (HistoryDealSelect(deal))
                    {
                        long position = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
                        Output("Position ID: " + IntegerToString(position));

                        if (!Trade.PositionModify(position, sl, tp))
                        {
                            Output("Error modifying position: " + IntegerToString(GetLastError()));
                        }
                        else
                        {
                            Output("SL/TP applied successfully.");
                            return deal;
                        }
                    }
                    else
                    {
                        Output("Error selecting deal: " + IntegerToString(GetLastError()));
                    }
                }
                else
                {
                    Output("Error selecting deal history: " + IntegerToString(GetLastError()));
                }
            }
            // Wait for position to open then find it using the order ID.
            else
            {
                // Run a waiting cycle until the order becomes a positoin.
                for (int i = 0; i < 10; i++)
                {
                    Output("Waiting...");
                    Sleep(1000);
                    if (PositionSelectByTicket(order)) break;
                }
                if (!PositionSelectByTicket(order))
                {
                    Output("Error selecting position: " + IntegerToString(GetLastError()));
                }
                else
                {
                    if (!Trade.PositionModify(order, sl, tp))
                    {
                        Output("Error modifying position: " + IntegerToString(GetLastError()));
                    }
                    else
                    {
                        Output("SL/TP applied successfully.");
                        return order;
                    }
                }
            }
        }
        if (deal != 0) return deal;
        else return order;
    }
    return 0;
}
//+------------------------------------------------------------------+