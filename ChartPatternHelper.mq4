//+------------------------------------------------------------------+
//|                                             Chart Pattern Helper |
//|                             Copyright © 2013-2022, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2013-2022, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/ChartPatternHelper/"
#property version   "1.11"
#property strict

#include <stdlib.mqh>

#property description "Uses graphic objects (horizontal/trend lines, channels) to enter trades."
#property description "Works in two modes:"
#property description "1. Price is below upper entry and above lower entry. Only one or two pending stop orders are used."
#property description "2. Price is above upper entry or below lower entry. Only one pending limit order is used."
#property description "If an object is deleted/renamed after the pending order was placed, order will be canceled."
#property description "Pending order is removed if opposite entry is triggered."
#property description "Generally, it is safe to turn off the EA at any point."

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
int UpperTicket, LowerTicket;
bool HaveBuyPending = false;
bool HaveSellPending = false;
bool HaveBuy = false;
bool HaveSell = false;
bool TCBusy = false;
bool PostBuySLAdjustmentDone = false, PostSellSLAdjustmentDone = false;
// For tick value adjustment:
string ProfitCurrency = "", account_currency = "", BaseCurrency = "", ReferenceSymbol = NULL, AdditionalReferenceSymbol = NULL;
bool ReferenceSymbolMode, AdditionalReferenceSymbolMode;
int ProfitCalcMode;
double TickSize;

// For error logging:
string filename;

void OnInit()
{
    FindObjects();
    if (ErrorLogging)
    {
        datetime tl = TimeLocal();
        string mon = IntegerToString(TimeMonth(tl));
        if (StringLen(mon) == 1) mon = "0" + mon;
        string day = IntegerToString(TimeDay(tl));
        if (StringLen(day) == 1) day = "0" + day;
        string hour = IntegerToString(TimeHour(tl));
        if (StringLen(hour) == 1) hour = "0" + hour;
        string min = IntegerToString(TimeMinute(tl));
        if (StringLen(min) == 1) min = "0" + min;
        string sec = IntegerToString(TimeSeconds(tl));
        if (StringLen(sec) == 1) sec = "0" + sec;
        filename = "CPH-Errors-" + IntegerToString(TimeYear(tl)) + mon + day + hour + min + sec + ".log";
    }
}

void OnDeinit(const int reason)
{
    SetComment("");
}

void OnTick()
{
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

    // Entry
    if (OpenOnCloseAboveBelowTrendline) // Simple trendline entry doesn't need an entry line.
    {
        c = c + "\nUpper entry unnecessary.";
    }
    else if (ObjectFind(UpperEntryLine) > -1)
    {
        if ((ObjectType(UpperEntryLine) != OBJ_HLINE) && (ObjectType(UpperEntryLine) != OBJ_TREND))
        {
            Alert("Upper Entry Line should be either OBJ_HLINE or OBJ_TREND.");
            return("\nWrong Upper Entry Line object type.");
        }
        if (ObjectType(UpperEntryLine) != OBJ_HLINE) UpperEntry = NormalizeDouble(ObjectGetValueByShift(UpperEntryLine, 0), Digits);
        else UpperEntry = NormalizeDouble(ObjectGet(UpperEntryLine, OBJPROP_PRICE1), Digits); // Horizontal line value
        if (UseSpreadAdjustment) UpperEntry = NormalizeDouble(UpperEntry + MarketInfo(Symbol(), MODE_SPREAD) * Point, Digits);
        ObjectSet(UpperEntryLine, OBJPROP_RAY, true);
        c = c + "\nUpper entry found. Level: " + DoubleToStr(UpperEntry, Digits);
    }
    else
    {
        if (ObjectFind(EntryChannel) > -1)
        {
            if (ObjectType(EntryChannel) != OBJ_CHANNEL)
            {
                Alert("Entry Channel should be OBJ_CHANNEL.");
                return "\nWrong Entry Channel object type.";
            }
            UpperEntry = NormalizeDouble(FindUpperEntryViaChannel(), Digits);
            if (UseSpreadAdjustment) UpperEntry = NormalizeDouble(UpperEntry + MarketInfo(Symbol(), MODE_SPREAD) * Point, Digits);
            ObjectSet(EntryChannel, OBJPROP_RAY, true);
            c = c + "\nUpper entry found (via channel). Level: " + DoubleToStr(UpperEntry, Digits);
        }
        else
        {
            c = c + "\nUpper entry not found. No new position will be entered.";
            UseUpper = false;
        }
    }

    // Border
    if (ObjectFind(UpperBorderLine) > -1)
    {
        if ((ObjectType(UpperBorderLine) != OBJ_HLINE) && (ObjectType(UpperBorderLine) != OBJ_TREND))
        {
            Alert("Upper Border Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Upper Border Line object type.";
        }
        // Find upper SL
        UpperSL = FindUpperSL();
        ObjectSet(UpperBorderLine, OBJPROP_RAY, true);
        c = c + "\nUpper border found. Upper stop-loss level: " + DoubleToStr(UpperSL, Digits);
    }
    else // Try to find a channel.
    {
        if (ObjectFind(BorderChannel) > -1)
        {
            if (ObjectType(BorderChannel) != OBJ_CHANNEL)
            {
                Alert("Border Channel should be OBJ_CHANNEL.");
                return "\nWrong Border Channel object type.";
            }
            // Find upper SL
            UpperSL = FindUpperSLViaChannel();
            ObjectSet(BorderChannel, OBJPROP_RAY, true);
            c = c + "\nUpper border found (via channel). Upper stop-loss level: " + DoubleToStr(UpperSL, Digits);
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
                // Track current SL, possibly installed by user.
                if ((OrderSelect(UpperTicket, SELECT_BY_TICKET)) && ((OrderType() == OP_BUYSTOP) || (OrderType() == OP_BUYLIMIT)))
                {
                    UpperSL = OrderStopLoss();
                }
            }
        }
    }
    // Adjust upper SL for tick size granularity.
    TickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
    UpperSL = NormalizeDouble(MathRound(UpperSL / TickSize) * TickSize, _Digits);

    // Take-profit.
    if (ObjectFind(UpperTPLine) > -1)
    {
        if ((ObjectType(UpperTPLine) != OBJ_HLINE) && (ObjectType(UpperTPLine) != OBJ_TREND))
        {
            Alert("Upper TP Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Upper TP Line object type.";
        }
        if (ObjectType(UpperTPLine) != OBJ_HLINE) UpperTP = NormalizeDouble(ObjectGetValueByShift(UpperTPLine, 0), Digits);
        else UpperTP = NormalizeDouble(ObjectGet(UpperTPLine, OBJPROP_PRICE1), Digits); // Horizontal line value
        ObjectSet(UpperTPLine, OBJPROP_RAY, true);
        c = c + "\nUpper take-profit found. Level: " + DoubleToStr(UpperTP, Digits);
    }
    else
    {
        if (ObjectFind(TPChannel) > -1)
        {
            if (ObjectType(TPChannel) != OBJ_CHANNEL)
            {
                Alert("TP Channel should be OBJ_CHANNEL.");
                return "\nWrong TP Channel object type.";
            }
            UpperTP = FindUpperTPViaChannel();
            ObjectSet(TPChannel, OBJPROP_RAY, true);
            c = c + "\nUpper TP found (via channel). Level: " + DoubleToStr(UpperTP, Digits);
        }
        else
        {
            c = c + "\nUpper take-profit not found. Take-profit won\'t be applied to new positions.";
            // Track current TP, possibly installed by user
            if ((OrderSelect(UpperTicket, SELECT_BY_TICKET)) && ((OrderType() == OP_BUYSTOP) || (OrderType() == OP_BUYLIMIT)))
            {
                UpperTP = OrderTakeProfit();
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
    else if (ObjectFind(LowerEntryLine) > -1)
    {
        if ((ObjectType(LowerEntryLine) != OBJ_HLINE) && (ObjectType(LowerEntryLine) != OBJ_TREND))
        {
            Alert("Lower Entry Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Lower Entry Line object type.";
        }
        if (ObjectType(LowerEntryLine) != OBJ_HLINE) LowerEntry = NormalizeDouble(ObjectGetValueByShift(LowerEntryLine, 0), Digits);
        else LowerEntry = NormalizeDouble(ObjectGet(LowerEntryLine, OBJPROP_PRICE1), Digits); // Horizontal line value
        ObjectSet(LowerEntryLine, OBJPROP_RAY, true);
        c = c + "\nLower entry found. Level: " + DoubleToStr(LowerEntry, Digits);
    }
    else
    {
        if (ObjectFind(EntryChannel) > -1)
        {
            if (ObjectType(EntryChannel) != OBJ_CHANNEL)
            {
                Alert("Entry Channel should be OBJ_CHANNEL.");
                return "\nWrong Entry Channel object type.";
            }
            LowerEntry = FindLowerEntryViaChannel();
            ObjectSet(EntryChannel, OBJPROP_RAY, true);
            c = c + "\nLower entry found (via channel). Level: " + DoubleToStr(LowerEntry, Digits);
        }
        else
        {
            c = c + "\nLower entry not found. No new position will be entered.";
            UseLower = false;
        }
    }

    // Border.
    if (ObjectFind(LowerBorderLine) > -1)
    {
        if ((ObjectType(LowerBorderLine) != OBJ_HLINE) && (ObjectType(LowerBorderLine) != OBJ_TREND))
        {
            Alert("Lower Border Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Lower Border Line object type.";
        }
        // Find Lower SL.
        LowerSL = NormalizeDouble(FindLowerSL(), Digits);
        if (UseSpreadAdjustment) LowerSL = NormalizeDouble(LowerSL + MarketInfo(Symbol(), MODE_SPREAD) * Point, Digits);
        ObjectSet(LowerBorderLine, OBJPROP_RAY, true);
        c = c + "\nLower border found. Lower stop-loss level: " + DoubleToStr(LowerSL, Digits);
    }
    else // Try to find a channel.
    {
        if (ObjectFind(BorderChannel) > -1)
        {
            if (ObjectType(BorderChannel) != OBJ_CHANNEL)
            {
                Alert("Border Channel should be OBJ_CHANNEL.");
                return "\nWrong Border Channel object type.";
            }
            // Find Lower SL
            LowerSL = NormalizeDouble(FindLowerSLViaChannel(), Digits);
            if (UseSpreadAdjustment) LowerSL = NormalizeDouble(LowerSL + MarketInfo(Symbol(), MODE_SPREAD) * Point, Digits);
            ObjectSet(BorderChannel, OBJPROP_RAY, true);
            c = c + "\nLower border found (via channel). Lower stop-loss level: " + DoubleToStr(LowerSL, Digits);
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
                // Track current SL, possibly installed by user.
                if ((OrderSelect(LowerTicket, SELECT_BY_TICKET)) && ((OrderType() == OP_SELLSTOP) || (OrderType() == OP_SELLLIMIT)))
                {
                    LowerSL = OrderStopLoss();
                }
            }
        }
    }
    // Adjust lower SL for tick size granularity.
    TickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
    LowerSL = NormalizeDouble(MathRound(LowerSL / TickSize) * TickSize, _Digits);

    // Take-profit.
    if (ObjectFind(LowerTPLine) > -1)
    {
        if ((ObjectType(LowerTPLine) != OBJ_HLINE) && (ObjectType(LowerTPLine) != OBJ_TREND))
        {
            Alert("Lower TP Line should be either OBJ_HLINE or OBJ_TREND.");
            return "\nWrong Lower TP Line object type.";
        }
        if (ObjectType(LowerTPLine) != OBJ_HLINE) LowerTP = NormalizeDouble(ObjectGetValueByShift(LowerTPLine, 0), Digits);
        else LowerTP = NormalizeDouble(ObjectGet(LowerTPLine, OBJPROP_PRICE1), Digits); // Horizontal line value
        if (UseSpreadAdjustment) LowerTP = NormalizeDouble(LowerTP + MarketInfo(Symbol(), MODE_SPREAD) * Point, Digits);
        ObjectSet(LowerTPLine, OBJPROP_RAY, true);
        c = c + "\nLower take-profit found. Level: " + DoubleToStr(LowerTP, Digits);
    }
    else
    {
        if (ObjectFind(TPChannel) > -1)
        {
            if (ObjectType(TPChannel) != OBJ_CHANNEL)
            {
                Alert("TP Channel should be OBJ_CHANNEL.");
                return "\nWrong TP Channel object type.";
            }
            LowerTP = NormalizeDouble(FindLowerTPViaChannel(), Digits);
            if (UseSpreadAdjustment) LowerTP = NormalizeDouble(LowerTP + MarketInfo(Symbol(), MODE_SPREAD) * Point, Digits);
            ObjectSet(TPChannel, OBJPROP_RAY, true);
            c = c + "\nLower TP found (via channel). Level: " + DoubleToStr(LowerTP, Digits);
        }
        else
        {
            c = c + "\nLower take-profit not found. Take-profit won\'t be applied to new positions.";
            // Track current TP, possibly installed by user.
            if ((OrderSelect(LowerTicket, SELECT_BY_TICKET)) && ((OrderType() == OP_SELLSTOP) || (OrderType() == OP_SELLLIMIT)))
            {
                LowerTP = OrderTakeProfit();
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
        if (ObjectType(LowerBorderLine) == OBJ_HLINE)
        {
            return NormalizeDouble(ObjectGetDouble(0, LowerBorderLine, OBJPROP_PRICE1), Digits);
        }
        // Trend line.
        else if (ObjectType(LowerBorderLine) == OBJ_TREND)
        {
            double price1 = ObjectGetDouble(0, LowerBorderLine, OBJPROP_PRICE1);
            double price2 = ObjectGetDouble(0, LowerBorderLine, OBJPROP_PRICE2);
            if (price1 < price2) return NormalizeDouble(price1, Digits);
            else return NormalizeDouble(price2, Digits);
        }
    }

    // Easy stop-loss via a separate horizontal line when using trendline trading.
    if (OpenOnCloseAboveBelowTrendline)
    {
        if (ObjectFind(0, SLLine) < 0) return -1;
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE1), Digits);
    }

    for (int i = 0; i < Bars; i++)
    {
        double Border, Entry;
        if (ObjectType(UpperBorderLine) != OBJ_HLINE) Border = ObjectGetValueByShift(UpperBorderLine, i);
        else Border = ObjectGet(UpperBorderLine, OBJPROP_PRICE1); // Horizontal line value
        if (ObjectType(UpperEntryLine) != OBJ_HLINE) Entry = ObjectGetValueByShift(UpperEntryLine, i);
        else Entry = ObjectGet(UpperEntryLine, OBJPROP_PRICE1); // Horizontal line value
        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next bar's Low should be lower or equal to that of the first bar.
        if ((Border - Low[i] > High[i] - Border) && ((Entry - Border < Border - Low[i]) || (i != 0)) && (Low[i] <= Low[0])) return NormalizeDouble(Low[i], Digits);
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
        if (ObjectType(UpperBorderLine) == OBJ_HLINE)
        {
            return NormalizeDouble(ObjectGetDouble(0, UpperBorderLine, OBJPROP_PRICE1), Digits);
        }
        // Trend line.
        else if (ObjectType(UpperBorderLine) == OBJ_TREND)
        {
            double price1 = ObjectGetDouble(0, UpperBorderLine, OBJPROP_PRICE1);
            double price2 = ObjectGetDouble(0, UpperBorderLine, OBJPROP_PRICE2);
            if (price1 > price2) return NormalizeDouble(price1, Digits);
            else return NormalizeDouble(price2, Digits);
        }
    }

    // Easy stop-loss via a separate horizontal line when using trendline trading.
    if (OpenOnCloseAboveBelowTrendline)
    {
        if (ObjectFind(0, SLLine) < 0) return -1;
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE1), Digits);
    }

    for (int i = 0; i < Bars; i++)
    {
        double Border, Entry;
        if (ObjectType(LowerBorderLine) != OBJ_HLINE) Border = ObjectGetValueByShift(LowerBorderLine, i);
        else Border = ObjectGet(LowerBorderLine, OBJPROP_PRICE1); // Horizontal line value
        if (ObjectType(LowerEntryLine) != OBJ_HLINE) Entry = ObjectGetValueByShift(LowerEntryLine, i);
        else Entry = ObjectGet(LowerEntryLine, OBJPROP_PRICE1); // Horizontal line value
        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next bar's High should be higher or equal to that of the first bar.
        if ((High[i] - Border > Border - Low[i]) && ((Border - Entry < High[i] - Border) || (i != 0)) && (High[i] >= High[0]))
        {
            return NormalizeDouble(High[i], Digits);
        }
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
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE1), Digits);
    }

    for (int i = 0; i < Bars(_Symbol, _Period); i++)
    {
        // Get the upper of main and auxiliary lines
        double Border = MathMax(ObjectGetValueByTime(0, BorderChannel, Time[i], 0), ObjectGetValueByTime(0, BorderChannel, Time[i], 1));

        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next  bar's Low should be lower or equal to that of the first bar.
        if ((Border - Low[i] > High[i] - Border) && ((UpperEntry - Border < Border - Low[i]) || (i != 0)) && (Low[i] <= Low[0])) return(NormalizeDouble(Low[i], _Digits));
    }

    return(SL);
}

// Find SL using a border channel - the high of the first bar with major part above upper line.
double FindLowerSLViaChannel()
{
    // Invalid value will prevent order from executing in case something goes wrong.
    double SL = -1;

    // Easy stop-loss via a separate horizontal line when using trendline trading.
    if (OpenOnCloseAboveBelowTrendline)
    {
        if (ObjectFind(0, SLLine) < 0) return(-1);
        return NormalizeDouble(ObjectGetDouble(0, SLLine, OBJPROP_PRICE1), Digits);
    }

    for (int i = 0; i < Bars(_Symbol, _Period); i++)
    {
        // Get the lower of main and auxiliary lines
        double Border = MathMin(ObjectGetValueByTime(0, BorderChannel, Time[i], 0), ObjectGetValueByTime(0, BorderChannel, Time[i], 1));

        // Additional condition (Entry) checks whether _current_ candle may still have a bigger part within border before triggering entry.
        // It is not possible if the current height inside border is not bigger than the distance from border to entry.
        // It should not be checked for candles already completed.
        // Additionally, if skipped the first bar because it could not potentially qualify, next  bar's High should be higher or equal to that of the first bar.
        if ((High[i] - Border > Border - Low[i]) && ((Border - LowerEntry < High[i] - Border) || (i != 0)) && (High[i] >= High[0])) return(NormalizeDouble(High[i], _Digits));
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
    for (int i = 0; i < OrdersTotal(); i++)
    {
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) == false) continue;
        if (((OrderType() == OP_BUYSTOP) || (OrderType() == OP_BUYLIMIT)) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic))
        {
            HaveBuyPending = true;
            UpperTicket = OrderTicket();
        }
        else if (((OrderType() == OP_SELLSTOP) || (OrderType() == OP_SELLLIMIT)) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic))
        {
            HaveSellPending = true;
            LowerTicket = OrderTicket();
        }
        else if ((OrderType() == OP_BUY) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic)) HaveBuy = true;
        else if ((OrderType() == OP_SELL) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic)) HaveSell = true;
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
    if (ObjectFind(Object) > -1) // If exists
    {
        Print("Renaming ", Object, ".");
        // Get object's type, price/time coordinates, style properties.
        int OT = ObjectType(Object);
        double Price1 = ObjectGet(Object, OBJPROP_PRICE1);
        datetime Time1 = 0;
        double Price2 = 0;
        datetime Time2 = 0;
        double Price3 = 0;
        datetime Time3 = 0;
        if ((OT == OBJ_TREND) || (OT == OBJ_CHANNEL))
        {
            Time1 = (datetime)ObjectGet(Object, OBJPROP_TIME1);
            Price2 = ObjectGet(Object, OBJPROP_PRICE2);
            Time2 = (datetime)ObjectGet(Object, OBJPROP_TIME2);
            if (OT == OBJ_CHANNEL)
            {
                Price3 = ObjectGet(Object, OBJPROP_PRICE3);
                Time3 = (datetime)ObjectGet(Object, OBJPROP_TIME3);
            }
        }
        color Color = (color)ObjectGet(Object, OBJPROP_COLOR);
        int Style = (int)ObjectGet(Object, OBJPROP_STYLE);
        int Width = (int)ObjectGet(Object, OBJPROP_WIDTH);

        // Delete object.
        ObjectDelete(Object);

        // Create the same object with new name and set the old style properties.
        ObjectCreate(Object + IntegerToString(Magic), OT, 0, Time1, Price1, Time2, Price2, Time3, Price3);
        ObjectSet(Object + IntegerToString(Magic), OBJPROP_COLOR, Color);
        ObjectSet(Object + IntegerToString(Magic), OBJPROP_STYLE, Style);
        ObjectSet(Object + IntegerToString(Magic), OBJPROP_WIDTH, Width);
        ObjectSet(Object + IntegerToString(Magic), OBJPROP_RAY, true);
    }
}

// The main trading procedure. Sends, Modifies and Deletes orders.
void AdjustUpperAndLowerOrders()
{
    double NewVolume;
    int last_error;
    datetime expiration;
    int order_type;
    string order_type_string;

    if ((!IsTradeAllowed()) || (IsTradeContextBusy()) || (!IsConnected()) || (!MarketInfo(Symbol(), MODE_TRADEALLOWED)))
    {
        if (!TCBusy) Output("Trading context is busy or disconnected.");
        TCBusy = true;
        return;
    }
    else if (TCBusy)
    {
        Output("Trading context is no longer busy or disconnected.");
        TCBusy = false;
    }

    double StopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
    double FreezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
    double LotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    if (UseExpiration)
    {
        // Set expiration to the end of the current bar.
        expiration = Time[0] + Period() * 60;
        // If expiration is less than 11 minutes from now, set it to at least 11 minutes from now.
        // (Brokers have such limit.)
        if (expiration - TimeCurrent() < 660) expiration = TimeCurrent() + 660;
    }
    else expiration = 0;

    if (OpenOnCloseAboveBelowTrendline) // Simple case.
    {
        double BorderLevel;
        if ((LowerTP > 0) && (!HaveSell) && (UseLower)) // SELL.
        {
            if (ObjectFind(0, LowerBorderLine) >= 0) // Line.
            {
                BorderLevel = NormalizeDouble(ObjectGetValueByShift(LowerBorderLine, 1), _Digits);
            }
            else // Channel
            {
                BorderLevel = MathMin(ObjectGetValueByTime(0, BorderChannel, Time[1], 0), ObjectGetValueByTime(0, BorderChannel, Time[1], 1));
            }
            BorderLevel = NormalizeDouble(MathRound(BorderLevel / TickSize) * TickSize, _Digits);

            // Previous candle close significantly lower than the border line.
            if (BorderLevel - Close[1] >= SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * _Point * ThresholdSpreads)
            {
                RefreshRates();
                NewVolume = GetPositionSize(Bid, LowerSL);
                LowerTicket = ExecuteMarketOrder(OP_SELL, NewVolume, Bid, LowerSL, LowerTP);
            }
        }
        else if ((UpperTP > 0) && (!HaveBuy) && (UseUpper)) // BUY.
        {
            if (ObjectFind(0, UpperBorderLine) >= 0) // Line.
            {
                BorderLevel = NormalizeDouble(ObjectGetValueByShift(UpperBorderLine, 1), _Digits);
            }
            else // Channel
            {
                BorderLevel = MathMax(ObjectGetValueByTime(0, BorderChannel, Time[1], 0), ObjectGetValueByTime(0, BorderChannel, Time[1], 1));
            }
            BorderLevel = NormalizeDouble(MathRound(BorderLevel / TickSize) * TickSize, _Digits);

            // Previous candle close significantly higher than the border line.
            if (Close[1] - BorderLevel >= SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * _Point * ThresholdSpreads)
            {
                RefreshRates();
                NewVolume = GetPositionSize(Ask, UpperSL);
                UpperTicket = ExecuteMarketOrder(OP_SELL, NewVolume, Ask, UpperSL, UpperTP);
            }
        }
        return;
    }

    int OT = OrdersTotal();
    for (int i = OT - 1; i >= 0; i--)
    {
        double prevOrderOpenPrice, prevOrderStopLoss, prevOrderTakeProfit;
        double SL;
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        RefreshRates();
        // BUY
        if (((OrderType() == OP_BUYSTOP) || (OrderType() == OP_BUYLIMIT)) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic) && (!DisableBuyOrders))
        {
            // Current price is below Sell entry - pending Sell Limit will be used instead of two stop orders.
            if ((LowerEntry - Bid > StopLevel) && (UseLower)) continue;

            NewVolume = GetPositionSize(UpperEntry, UpperSL);
            // Delete existing pending order
            if ((HaveBuy) || ((HaveSell) && (OneCancelsOther)) || (!UseUpper))
            {
                if (!OrderDelete(OrderTicket()))
                {
                    last_error = GetLastError();
                    Output("OrderDelete() error. Order ticket = " + IntegerToString(OrderTicket()) + ". Error = " + IntegerToString(last_error));
                }
            }
            // If volume needs to be updated - delete and recreate order with new volume.
            // Also check if EA will be able to create new pending order at current price.
            else if ((UpdatePendingVolume) && (NormalizeDouble(OrderLots(), LotStep_digits) != NormalizeDouble(NewVolume, LotStep_digits)))
            {
                if ((UpperEntry - Ask > StopLevel) || (Ask - UpperEntry > StopLevel)) // Order can be re-created.
                {
                    if (!OrderDelete(OrderTicket()))
                    {
                        last_error = GetLastError();
                        Output("OrderDelete() error. Order ticket = " + IntegerToString(OrderTicket()) + ". Error = " + IntegerToString(last_error));
                    }
                    Sleep(5000); // Wait 5 seconds before opening a new order.
                }
                else continue;
                // Ask could change after deletion, check if there is still no error 130 present.
                RefreshRates();
                if (UpperEntry - Ask > StopLevel) // Current price below entry.
                {
                    order_type = OP_BUYSTOP;
                    order_type_string = "Stop";
                }
                else if (Ask - UpperEntry > StopLevel) // Current price above entry.
                {
                    order_type = OP_BUYLIMIT;
                    order_type_string = "Limit";
                }
                else continue;
                if (UseExpiration)
                {
                    // Set expiration to the end of the current bar.
                    expiration = Time[0] + Period() * 60;
                    // If expiration is less than 11 minutes extra seconds from now, set it to at least 11 minutes from now.
                    // (Brokers have such limit.)
                    if (expiration - TimeCurrent() < 660) expiration = TimeCurrent() + 661;
                }
                else expiration = 0;
                UpperTicket = OrderSend(Symbol(), order_type, NewVolume, UpperEntry, Slippage, UpperSL, UpperTP, "ChartPatternHelper", Magic, expiration);
                last_error = GetLastError();
                if ((UpperTicket == -1) && (last_error != 128)) // Ignore time-out errors.
                {
                    Output("StopLevel = " + DoubleToStr(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToStr(FreezeLevel, 8));
                    Output("Error Recreating Buy " + order_type_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                    Output("Volume = " + DoubleToStr(NewVolume, LotStep_digits) + " Entry = " + DoubleToStr(UpperEntry, Digits) + " SL = " + DoubleToStr(UpperSL, Digits) + " TP = " + DoubleToStr(UpperTP, Digits) + " Bid/Ask = " + DoubleToStr(Bid, Digits) + "/" + DoubleToStr(Ask, Digits) + " Exp: " + TimeToStr(expiration, TIME_DATE | TIME_SECONDS));
                }
                continue;
            }
            // Otherwise update entry/SL/TP if at least one of them has changed.
            else if ((NormalizeDouble(OrderOpenPrice(), Digits) != NormalizeDouble(UpperEntry, Digits)) || (NormalizeDouble(OrderStopLoss(), Digits) != NormalizeDouble(UpperSL, Digits)) || (NormalizeDouble(OrderTakeProfit(), Digits) != NormalizeDouble(UpperTP, Digits)))
            {
                // Avoid error 130 based on entry.
                if (UpperEntry - Ask > StopLevel) // Current price below entry.
                {
                    order_type_string = "Stop";
                }
                else if (Ask - UpperEntry > StopLevel) // Current price above entry.
                {
                    order_type_string = "Limit";
                }
                else if ((UpperEntry != OrderOpenPrice())) continue;
                // Avoid error 130 based on stop-loss.
                if (UpperEntry - UpperSL <= StopLevel)
                {
                    Output("Skipping Modify Buy " + order_type_string + " because stop-loss is too close to entry. StopLevel = " + DoubleToStr(StopLevel, Digits) + " Entry = " + DoubleToStr(UpperEntry, Digits) + " SL = " + DoubleToStr(UpperSL, Digits));
                    continue;
                }
                // Avoid frozen context. In all modification cases.
                if ((FreezeLevel != 0) && (MathAbs(OrderOpenPrice() - Ask) <= FreezeLevel))
                {
                    Output("Skipping Modify Buy " + order_type_string +  " because open price is too close to Ask. FreezeLevel = " + DoubleToStr(FreezeLevel, Digits) + " OpenPrice = " + DoubleToStr(OrderOpenPrice(), Digits) + " Ask = " + DoubleToStr(Ask, Digits));
                    continue;
                }
                if (UseExpiration)
                {
                    expiration = OrderExpiration();
                    if (expiration - TimeCurrent() < 660) expiration = TimeCurrent() + 660;
                }
                else expiration = 0;
                prevOrderOpenPrice = OrderOpenPrice();
                prevOrderStopLoss = OrderStopLoss();
                prevOrderTakeProfit = OrderTakeProfit();
                if (!OrderModify(OrderTicket(), UpperEntry, UpperSL, UpperTP, expiration))
                {
                    last_error = GetLastError();
                    if (last_error != 128) // Ignore time out errors.
                    {
                        if (last_error == 1)
                        {
                            Output("PREV: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " SL = " + DoubleToStr(OrderStopLoss(), Digits) + " TP = " + DoubleToStr(OrderTakeProfit(), Digits));
                        }
                        Output("StopLevel = " + DoubleToStr(StopLevel, 8));
                        Output("FreezeLevel = " + DoubleToStr(FreezeLevel, 8));
                        Output("Error Modifying Buy " + order_type_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                        Output("FROM: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " SL = " + DoubleToStr(OrderStopLoss(), Digits) + " TP = " + DoubleToStr(OrderTakeProfit(), Digits) + " -> TO: Entry = " + DoubleToStr(UpperEntry, 8) + " SL = " + DoubleToStr(UpperSL, 8) + " TP = " + DoubleToStr(UpperTP, 8) + " Bid/Ask = " + DoubleToStr(Bid, Digits) + "/" + DoubleToStr(Ask, Digits) + " OrderTicket = " + IntegerToString(OrderTicket()) + " OrderExpiration = " + TimeToStr(OrderExpiration(), TIME_DATE | TIME_SECONDS) + " -> " + TimeToStr(expiration, TIME_DATE | TIME_SECONDS));
                    }
                }
            }
        }
        else if ((OrderType() == OP_BUY) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic) && (!DisableBuyOrders))
        {
            // PostEntrySLAdjustment - a procedure to correct SL if breakout candle become too long and no longer qualifies for SL rule.
            if ((OrderOpenTime() > Time[1]) && (OrderOpenTime() < Time[0]) && (PostEntrySLAdjustment) && (PostBuySLAdjustmentDone == false))
            {
                SL = AdjustPostBuySL();
                if (SL != -1)
                {
                    // Avoid frozen context. In all modification cases.
                    if ((FreezeLevel != 0) && (MathAbs(OrderOpenPrice() - Ask) <= FreezeLevel))
                    {
                        Output("Skipping Modify Buy Stop SL because open price is too close to Ask. FreezeLevel = " + DoubleToStr(FreezeLevel, Digits) + " OpenPrice = " + DoubleToStr(OrderOpenPrice(), 8) + " Ask = " + DoubleToStr(Ask, Digits));
                        continue;
                    }
                    if (NormalizeDouble(SL, Digits) == NormalizeDouble(OrderStopLoss(), Digits)) PostBuySLAdjustmentDone = true;
                    else
                    {
                        if (!OrderModify(OrderTicket(), OrderOpenPrice(), SL, OrderTakeProfit(), OrderExpiration()))
                        {
                            last_error = GetLastError();
                            if (last_error != 128) // Ignore time out errors.
                            {
                                Output("Error Modifying Buy SL: " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                                Output("FROM: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " SL = " + DoubleToStr(OrderStopLoss(), Digits) + " -> TO: Entry = " + DoubleToStr(OrderOpenPrice(), 8) + " SL = " + DoubleToStr(SL, 8) + " Ask = " + DoubleToStr(Ask, Digits));
                            }
                        }
                        else PostBuySLAdjustmentDone = true;
                    }
                }
            }
            // Adjust TP only.
            if ((NormalizeDouble(OrderTakeProfit(), Digits) != NormalizeDouble(UpperTP, Digits)))
            {
                // Avoid frozen context. In all modification cases.
                if ((FreezeLevel != 0) && (MathAbs(OrderOpenPrice() - Ask) <= FreezeLevel))
                {
                    Output("Skipping Modify Buy Stop TP because open price is too close to Ask. FreezeLevel = " + DoubleToStr(FreezeLevel, Digits) + " OpenPrice = " + DoubleToStr(OrderOpenPrice(), 8) + " Ask = " + DoubleToStr(Ask, Digits));
                    continue;
                }
                if (!OrderModify(OrderTicket(), OrderOpenPrice(), OrderStopLoss(), UpperTP, OrderExpiration()))
                {
                    last_error = GetLastError();
                    if (last_error != 128) // Ignore time out errors.
                    {
                        Output("Error Modifying Buy TP: " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                        Output("FROM: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " TP = " + DoubleToStr(OrderTakeProfit(), Digits) + " -> TO: Entry = " + DoubleToStr(OrderOpenPrice(), 8) + " TP = " + DoubleToStr(UpperTP, 8) + " Ask = " + DoubleToStr(Ask, Digits));
                    }
                }
            }
        }
        // SELL
        else if (((OrderType() == OP_SELLSTOP) || (OrderType() == OP_SELLLIMIT)) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic) && (!DisableSellOrders))
        {
            // Current price is above Buy entry - pending Buy Limit will be used instead of two stop orders.
            if ((Ask - UpperEntry > StopLevel) && (UseUpper)) continue;

            NewVolume = GetPositionSize(LowerEntry, LowerSL);
            // Delete existing pending order.
            if (((HaveBuy) && (OneCancelsOther)) || (HaveSell) || (!UseLower))
            {
                if (!OrderDelete(OrderTicket()))
                {
                    last_error = GetLastError();
                    Output("OrderDelete() error. Order ticket = " + IntegerToString(OrderTicket()) + ". Error = " + IntegerToString(last_error));
                }
            }
            // If volume needs to be updated - delete and recreate order with new volume. Also check if EA will be able to create new pending order at current price.
            else if ((UpdatePendingVolume) && (NormalizeDouble(OrderLots(), Digits) != NormalizeDouble(NewVolume, Digits)))
            {
                if ((Bid - LowerEntry > StopLevel) || (LowerEntry - Bid > StopLevel)) // Order can be re-created
                {
                    if (!OrderDelete(OrderTicket()))
                    {
                        last_error = GetLastError();
                        Output("OrderDelete() error. Order ticket = " + IntegerToString(OrderTicket()) + ". Error = " + IntegerToString(last_error));
                    }
                }
                else continue;

                // Bid could change after deletion, check if there is still no error 130 present.
                RefreshRates();
                if (Bid - LowerEntry > StopLevel) // Current price above entry.
                {
                    order_type = OP_BUYSTOP;
                    order_type_string = "Stop";
                }
                else if (LowerEntry - Bid > StopLevel) // Current price below entry.
                {
                    order_type = OP_BUYLIMIT;
                    order_type_string = "Limit";
                }
                else continue;
                if (UseExpiration)
                {
                    // Set expiration to the end of the current bar.
                    expiration = Time[0] + Period() * 60;
                    // If expiration is less than 11 minutes extra seconds from now, set it to at least 11 minutes from now.
                    // (Brokers have such limit.)
                    if (expiration - TimeCurrent() < 660) expiration = TimeCurrent() + 661;
                }
                else expiration = 0;
                LowerTicket = OrderSend(Symbol(), order_type, NewVolume, LowerEntry, Slippage, LowerSL, LowerTP, "ChartPatternHelper", Magic, expiration);
                last_error = GetLastError();
                if ((LowerTicket == -1) && (last_error != 128)) // Ignore time-out errors.
                {
                    Output("StopLevel = " + DoubleToStr(StopLevel, 8));
                    Output("FreezeLevel = " + DoubleToStr(FreezeLevel, 8));
                    Output("Error Recreating Sell " + order_type_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                    Output("Volume = " + DoubleToStr(NewVolume, LotStep_digits) + " Entry = " + DoubleToStr(LowerEntry, Digits) + " SL = " + DoubleToStr(LowerSL, Digits) + " TP = " + DoubleToStr(LowerTP, Digits) + " Bid/Ask = " + DoubleToStr(Bid, Digits) + "/" + DoubleToStr(Ask, Digits) + " Exp: " + TimeToStr(expiration, TIME_DATE | TIME_SECONDS));
                }
                continue;
            }
            // Otherwise just update what needs to be updated.
            else if ((NormalizeDouble(OrderOpenPrice(), Digits) != NormalizeDouble(LowerEntry, Digits)) || (NormalizeDouble(OrderStopLoss(), Digits) != NormalizeDouble(LowerSL, Digits)) || (NormalizeDouble(OrderTakeProfit(), Digits) != NormalizeDouble(LowerTP, Digits)))
            {
                // Avoid error 130 based on entry.
                if (Bid - LowerEntry > StopLevel) // Current price above entry.
                {
                    order_type_string = "Stop";
                }
                else if (LowerEntry - Bid > StopLevel) // Current price below entry.
                {
                    order_type_string = "Limit";
                }
                else if (LowerEntry != OrderOpenPrice()) continue;
                // Avoid error 130 based on stop-loss.
                if (LowerSL - LowerEntry <= StopLevel)
                {
                    Output("Skipping Modify Sell " + order_type_string + " because stop-loss is too close to entry. StopLevel = " + DoubleToStr(StopLevel, Digits) + " Entry = " + DoubleToStr(LowerEntry, Digits) + " SL = " + DoubleToStr(LowerSL, Digits));
                    continue;
                }
                // Avoid frozen context. In all modification cases.
                if ((FreezeLevel != 0) && (MathAbs(Bid - OrderOpenPrice()) <= FreezeLevel))
                {
                    Output("Skipping Modify Sell " + order_type_string + " because open price is too close to Bid. FreezeLevel = " + DoubleToStr(FreezeLevel, Digits) + " OpenPrice = " + DoubleToStr(OrderOpenPrice(), Digits) + " Bid = " + DoubleToStr(Bid, Digits));
                    continue;
                }
                if (UseExpiration)
                {
                    expiration = OrderExpiration();
                    if (expiration - TimeCurrent() < 660) expiration = TimeCurrent() + 660;
                }
                else expiration = 0;
                prevOrderOpenPrice = OrderOpenPrice();
                prevOrderStopLoss = OrderStopLoss();
                prevOrderTakeProfit = OrderTakeProfit();
                if (!OrderModify(OrderTicket(), LowerEntry, LowerSL, LowerTP, expiration))
                {
                    last_error = GetLastError();
                    if (last_error != 128) // Ignore time out errors.
                    {
                        if (last_error == 1)
                        {
                            Output("PREV: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " SL = " + DoubleToStr(OrderStopLoss(), Digits) + " TP = " + DoubleToStr(OrderTakeProfit(), Digits));
                        }
                        Output("StopLevel = " + DoubleToStr(StopLevel, 8));
                        Output("FreezeLevel = " + DoubleToStr(FreezeLevel, 8));
                        Output("Error Modifying Sell " + order_type_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                        Output("FROM: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " SL = " + DoubleToStr(OrderStopLoss(), Digits) + " TP = " + DoubleToStr(OrderTakeProfit(), Digits) + " -> TO: Entry = " + DoubleToStr(LowerEntry, 8) + " SL = " + DoubleToStr(LowerSL, 8) + " TP = " + DoubleToStr(LowerTP, 8) + " Bid/Ask = " + DoubleToStr(Bid, Digits) + "/" + DoubleToStr(Ask, Digits) + " OrderTicket = " + IntegerToString(OrderTicket()) + " OrderExpiration = " + TimeToStr(OrderExpiration(), TIME_DATE | TIME_SECONDS) + " -> " + TimeToStr(expiration, TIME_DATE | TIME_SECONDS));
                    }
                }
            }
        }
        else if ((OrderType() == OP_SELL) && (OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic) && (!DisableSellOrders))
        {
            // PostEntrySLAdjustment - a procedure to correct SL if breakout candle become too long and no longer qualifies for SL rule.
            if ((OrderOpenTime() > Time[1]) && (OrderOpenTime() < Time[0]) && (PostEntrySLAdjustment) && (PostSellSLAdjustmentDone == false))
            {
                SL = AdjustPostSellSL();
                if (SL != -1)
                {
                    // Avoid frozen context. In all modification cases.
                    if ((FreezeLevel != 0) && (MathAbs(Bid - OrderOpenPrice()) <= FreezeLevel))
                    {
                        Output("Skipping Modify Sell Stop SL because open price is too close to Bid. FreezeLevel = " + DoubleToStr(FreezeLevel, Digits) + " OpenPrice = " + DoubleToStr(OrderOpenPrice(), 8) + " Bid = " + DoubleToStr(Bid, Digits));
                        continue;
                    }
                    if (NormalizeDouble(SL, Digits) == NormalizeDouble(OrderStopLoss(), Digits)) PostSellSLAdjustmentDone = true;
                    else
                    {
                        if (!OrderModify(OrderTicket(), OrderOpenPrice(), SL, OrderTakeProfit(), OrderExpiration()))
                        {
                            last_error = GetLastError();
                            if (last_error != 128) // Ignore time out errors.
                            {
                                Output("Error Modifying Sell SL: " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                                Output("FROM: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " SL = " + DoubleToStr(OrderStopLoss(), Digits) + " -> TO: Entry = " + DoubleToStr(OrderOpenPrice(), 8) + " SL = " + DoubleToStr(SL, 8) + " Bid = " + DoubleToStr(Bid, Digits));
                            }
                        }
                        else PostSellSLAdjustmentDone = true;
                    }
                }
            }
            // Adjust TP only.
            if ((NormalizeDouble(OrderTakeProfit(), Digits) != NormalizeDouble(LowerTP, Digits)))
            {
                // Avoid frozen context. In all modification cases.
                if ((FreezeLevel != 0) && (MathAbs(Bid - OrderOpenPrice()) <= FreezeLevel))
                {
                    Output("Skipping Modify Sell Stop TP because open price is too close to Bid. FreezeLevel = " + DoubleToStr(FreezeLevel, Digits) + " OpenPrice = " + DoubleToStr(OrderOpenPrice(), 8) + " Bid = " + DoubleToStr(Bid, Digits));
                    continue;
                }
                if (!OrderModify(OrderTicket(), OrderOpenPrice(), OrderStopLoss(), LowerTP, OrderExpiration()))
                {
                    last_error = GetLastError();
                    if (last_error != 128) // Ignore time out errors.
                    {
                        Output("Error Modifying Sell Stop TP: " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                        Output("FROM: Entry = " + DoubleToStr(OrderOpenPrice(), Digits) + " TP = " + DoubleToStr(OrderTakeProfit(), Digits) + " -> TO: Entry = " + DoubleToStr(OrderOpenPrice(), 8) + " TP = " + DoubleToStr(LowerTP, 8) + " Bid = " + DoubleToStr(Bid, Digits));
                    }
                }
            }
        }
    }

    // BUY
    // If we do not already have Long position or Long pending order and if we can enter Long
    // and the current price is not below the Sell entry (in that case, only pending Sell Limit order will be used).
    if ((!HaveBuy) && (!HaveBuyPending) && (UseUpper) && ((LowerEntry - Bid <= StopLevel) || (!UseLower)))
    {
        // Avoid error 130 based on stop-loss.
        if (UpperEntry - UpperSL <= StopLevel)
        {
            Output("Skipping Send Pending Buy because stop-loss is too close to entry. StopLevel = " + DoubleToStr(StopLevel, Digits) + " Entry = " + DoubleToStr(UpperEntry, Digits) + " SL = " + DoubleToStr(UpperSL, Digits));
        }
        else
        {
            if (UpperEntry - Ask > StopLevel) // Current price below entry.
            {
                order_type = OP_BUYSTOP;
                order_type_string = "Stop";
            }
            else if (Ask - UpperEntry > StopLevel) // Current price above entry.
            {
                order_type = OP_BUYLIMIT;
                order_type_string = "Limit";
            }
            else
            {
                order_type = -1;
                Output("Skipping Send Pending Buy because entry is too close to Ask. StopLevel = " + DoubleToStr(StopLevel, Digits) + " Entry = " + DoubleToStr(UpperEntry, Digits) + " Ask = " + DoubleToStr(Ask, Digits));
            }
            if (order_type > -1)
            {
                NewVolume = GetPositionSize(UpperEntry, UpperSL);
                UpperTicket = OrderSend(Symbol(), order_type, NewVolume, UpperEntry, Slippage, UpperSL, UpperTP, "ChartPatternHelper", Magic, expiration);
                last_error = GetLastError();
                if ((UpperTicket == -1) && (last_error != 128)) // Ignore time-out errors
                {
                    Output("Error Sending Buy " + order_type_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                    Output("Volume = " + DoubleToStr(NewVolume, LotStep_digits) + " Entry = " + DoubleToStr(UpperEntry, Digits) + " SL = " + DoubleToStr(UpperSL, Digits) + " TP = " + DoubleToStr(UpperTP, Digits) + " Ask = " + DoubleToStr(Ask, Digits) + " Exp: " + TimeToStr(expiration, TIME_DATE | TIME_SECONDS));
                }
            }
        }
    }

    // SELL
    // If we do not already have Short position or Short pending order and if we can enter Short
    // and the current price is not above the Buy entry (in that case, only pending Buy  Limit order will be used).
    if ((!HaveSell) && (!HaveSellPending) && (UseLower) && ((Ask - UpperEntry <= StopLevel) || (!UseUpper)))
    {
        // Avoid error 130 based on stop-loss.
        if (LowerSL - LowerEntry <= StopLevel)
        {
            Output("Skipping Send Pending Sell because stop-loss is too close to entry. StopLevel = " + DoubleToStr(StopLevel, Digits) + " Entry = " + DoubleToStr(LowerEntry, Digits) + " SL = " + DoubleToStr(LowerSL, Digits));
        }
        else
        {
            if (Bid - LowerEntry > StopLevel) // Current price above entry.
            {
                order_type = OP_SELLSTOP;
                order_type_string = "Stop";
            }
            else if (LowerEntry - Bid > StopLevel) // Current price below entry.
            {
                order_type = OP_SELLLIMIT;
                order_type_string = "Limit";
            }
            else
            {
                order_type = -1;
                Output("Skipping Send Pending Sell because entry is too close to Bid. StopLevel = " + DoubleToStr(StopLevel, Digits) + " Entry = " + DoubleToStr(LowerEntry, Digits) + " Bid = " + DoubleToStr(Bid, Digits));
            }
            if (order_type > -1)
            {
                NewVolume = GetPositionSize(LowerEntry, LowerSL);
                LowerTicket = OrderSend(Symbol(), order_type, NewVolume, LowerEntry, Slippage, LowerSL, LowerTP, "ChartPatternHelper", Magic, expiration);
                last_error = GetLastError();
                if ((LowerTicket == -1) && (last_error != 128)) // Ignore time-out errors
                {
                    Output("Error Sending Sell " + order_type_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
                    Output("Volume = " + DoubleToStr(NewVolume, LotStep_digits) + " Entry = " + DoubleToStr(LowerEntry, Digits) + " SL = " + DoubleToStr(LowerSL, Digits) + " TP = " + DoubleToStr(LowerTP, Digits) + " Bid = " + DoubleToStr(Bid, Digits) + " Exp: " + TimeToStr(expiration, TIME_DATE | TIME_SECONDS));
                }
            }
        }
    }
}

void SetComment(string c)
{
    if (!Silent) Comment(c);
}

//+-----------------------------------------------------------------------------------+
//| Calculates necessary adjustments for cases when ProfitCurrency != AccountCurrency.|
//+-----------------------------------------------------------------------------------+
#define FOREX_SYMBOLS_ONLY 0
#define NONFOREX_SYMBOLS_ONLY 1
double CalculateAdjustment()
{
    double add_coefficient = 1; // Might be necessary for correction coefficient calculation if two pairs are used for profit currency to account currency conversion. This is handled differently in MT5 version.
    if (ReferenceSymbol == NULL)
    {
        ReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, account_currency, FOREX_SYMBOLS_ONLY);
        if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, account_currency, NONFOREX_SYMBOLS_ONLY);
        ReferenceSymbolMode = true;
        // Failed.
        if (ReferenceSymbol == NULL)
        {
            // Reversing currencies.
            ReferenceSymbol = GetSymbolByCurrencies(account_currency, ProfitCurrency, FOREX_SYMBOLS_ONLY);
            if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(account_currency, ProfitCurrency, NONFOREX_SYMBOLS_ONLY);
            ReferenceSymbolMode = false;
        }
        if (ReferenceSymbol == NULL)
        {
            // The condition checks whether we are caclulating conversion coefficient for the chart's symbol or for some other.
            // The error output is OK for the current symbol only because it won't be repeated ad infinitum.
            // It should be avoided for non-chart symbols because it will just flood the log.
            Print("Couldn't detect proper currency pair for adjustment calculation. Profit currency: ", ProfitCurrency, ". Account currency: ", account_currency, ". Trying to find a possible two-symbol combination.");
            if ((FindDoubleReferenceSymbol("USD"))  // USD should work in 99.9% of cases.
             || (FindDoubleReferenceSymbol("EUR"))  // For very rare cases.
             || (FindDoubleReferenceSymbol("GBP"))  // For extremely rare cases.
             || (FindDoubleReferenceSymbol("JPY"))) // For extremely rare cases.
            {
                Print("Converting via ", ReferenceSymbol, " and ", AdditionalReferenceSymbol, ".");
            }
            else
            {
                Print("Adjustment calculation critical failure. Failed both simple and two-pair conversion methods.");
                return 1;
            }
        }
    }
    if (AdditionalReferenceSymbol != NULL) // If two reference pairs are used.
    {
        // Calculate just the additional symbol's coefficient and then use it in final return's multiplication.
        MqlTick tick;
        SymbolInfoTick(AdditionalReferenceSymbol, tick);
        add_coefficient = GetCurrencyCorrectionCoefficient(tick, AdditionalReferenceSymbolMode);
    }
    MqlTick tick;
    SymbolInfoTick(ReferenceSymbol, tick);
    return GetCurrencyCorrectionCoefficient(tick, ReferenceSymbolMode) * add_coefficient;
}

//+---------------------------------------------------------------------------+
//| Returns a currency pair with specified base currency and profit currency. |
//+---------------------------------------------------------------------------+
string GetSymbolByCurrencies(const string base_currency, const string profit_currency, const uint symbol_type)
{
    // Cycle through all symbols.
    for (int s = 0; s < SymbolsTotal(false); s++)
    {
        // Get symbol name by number.
        string symbolname = SymbolName(s, false);
        string b_cur;

        // Normal case - Forex pairs:
        if (MarketInfo(symbolname, MODE_PROFITCALCMODE) == 0)
        {
            if (symbol_type == NONFOREX_SYMBOLS_ONLY) continue; // Avoid checking symbols of a wrong type.
            // Get its base currency.
            b_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_BASE);
            if (b_cur == "RUR") b_cur = "RUB";
        }
        else // Weird case for brokers that set conversion pairs as CFDs.
        {
            if (symbol_type == FOREX_SYMBOLS_ONLY) continue; // Avoid checking symbols of a wrong type.
            // Get its base currency as the initial three letters - prone to huge errors!
            b_cur = StringSubstr(symbolname, 0, 3);
        }

        // Get its profit currency.
        string p_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_PROFIT);
        if (p_cur == "RUR") p_cur = "RUB";

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

//+----------------------------------------------------------------------------+
//| Finds reference symbols using 2-pair method.                               |
//| Results are returned via reference parameters.                             |
//| Returns true if found the pairs, false otherwise.                          |
//+----------------------------------------------------------------------------+
bool FindDoubleReferenceSymbol(const string cross_currency)
{
    // A hypothetical example for better understanding:
    // The trader buys CAD/CHF.
    // account_currency is known = SEK.
    // cross_currency = USD.
    // profit_currency = CHF.
    // I.e., we have to buy dollars with francs (using the Ask price) and then sell those for SEKs (using the Bid price).

    ReferenceSymbol = GetSymbolByCurrencies(cross_currency, account_currency, FOREX_SYMBOLS_ONLY); 
    if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(cross_currency, account_currency, NONFOREX_SYMBOLS_ONLY);
    ReferenceSymbolMode = true; // If found, we've got USD/SEK.

    // Failed.
    if (ReferenceSymbol == NULL)
    {
        // Reversing currencies.
        ReferenceSymbol = GetSymbolByCurrencies(account_currency, cross_currency, FOREX_SYMBOLS_ONLY);
        if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(account_currency, cross_currency, NONFOREX_SYMBOLS_ONLY);
        ReferenceSymbolMode = false; // If found, we've got SEK/USD.
    }
    if (ReferenceSymbol == NULL)
    {
        Print("Error. Couldn't detect proper currency pair for 2-pair adjustment calculation. Cross currency: ", cross_currency, ". Account currency: ", account_currency, ".");
        return false;
    }

    AdditionalReferenceSymbol = GetSymbolByCurrencies(cross_currency, ProfitCurrency, FOREX_SYMBOLS_ONLY); 
    if (AdditionalReferenceSymbol == NULL) AdditionalReferenceSymbol = GetSymbolByCurrencies(cross_currency, ProfitCurrency, NONFOREX_SYMBOLS_ONLY);
    AdditionalReferenceSymbolMode = false; // If found, we've got USD/CHF. Notice that mode is swapped for cross/profit compared to cross/acc, because it is used in the opposite way.

    // Failed.
    if (AdditionalReferenceSymbol == NULL)
    {
        // Reversing currencies.
        AdditionalReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, cross_currency, FOREX_SYMBOLS_ONLY);
        if (AdditionalReferenceSymbol == NULL) AdditionalReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, cross_currency, NONFOREX_SYMBOLS_ONLY);
        AdditionalReferenceSymbolMode = true; // If found, we've got CHF/USD. Notice that mode is swapped for profit/cross compared to acc/cross, because it is used in the opposite way.
    }
    if (AdditionalReferenceSymbol == NULL)
    {
        Print("Error. Couldn't detect proper currency pair for 2-pair adjustment calculation. Cross currency: ", cross_currency, ". Chart's pair currency: ", ProfitCurrency, ".");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Get profit correction coefficient based on current prices.       |
//| Valid for loss calculation only.                                 |
//+------------------------------------------------------------------+
double GetCurrencyCorrectionCoefficient(MqlTick &tick, const bool ref_symbol_mode)
{
    if ((tick.ask == 0) || (tick.bid == 0)) return -1; // Data is not yet ready.
    // Reverse quote.
    if (ref_symbol_mode)
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

// Taken from PositionSizeCalculator indicator.
double GetPositionSize(double Entry, double StopLoss)
{
    double Size, RiskMoney, UnitCost, PositionSize = 0;
    ProfitCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_PROFIT);
    BaseCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_BASE);
    ProfitCalcMode = (int)MarketInfo(Symbol(), MODE_PROFITCALCMODE);
    account_currency = AccountCurrency();

    // A rough patch for cases when account currency is set as RUR instead of RUB.
    if (account_currency == "RUR") account_currency = "RUB";
    if (ProfitCurrency == "RUR") ProfitCurrency = "RUB";
    if (BaseCurrency == "RUR") BaseCurrency = "RUB";

    double LotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    double SL = MathAbs(Entry - StopLoss);

    if (!CalculatePositionSize) return FixedPositionSize;

    if (AccountCurrency() == "") return 0;

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountEquity();
    }
    else
    {
        Size = AccountBalance();
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    // If Symbol is CFD.
    if (ProfitCalcMode == 1)
        UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE) * SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE); // Apparently, it is more accurate than taking TICKVALUE directly in some cases.
    else UnitCost = MarketInfo(Symbol(), MODE_TICKVALUE); // Futures or Forex.

    if (ProfitCalcMode != 0)  // Non-Forex might need to be adjusted.
    {
        // If profit currency is different from account currency.
        if (ProfitCurrency != account_currency)
        {
            double CCC = CalculateAdjustment(); // Valid only for loss calculation.
            // Adjust the unit cost.
            UnitCost *= CCC;
        }
    }

    // If account currency == pair's base currency, adjust UnitCost to future rate (SL). Works only for Forex pairs.
    if ((account_currency == BaseCurrency) && (ProfitCalcMode == 0))
    {
        double current_rate = 1, future_rate = StopLoss;
        RefreshRates();
        if (StopLoss < Entry)
        {
            current_rate = Ask;
        }
        else if (StopLoss > Entry)
        {
            current_rate = Bid;
        }
        UnitCost *= (current_rate / future_rate);
    }

    if ((SL != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (SL * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < MarketInfo(Symbol(), MODE_MINLOT)) PositionSize = MarketInfo(Symbol(), MODE_MINLOT);
    else if (PositionSize > MarketInfo(Symbol(), MODE_MAXLOT)) PositionSize = MarketInfo(Symbol(), MODE_MAXLOT);
    double steps = PositionSize / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (MathFloor(steps) < steps) PositionSize = MathFloor(steps) * MarketInfo(Symbol(), MODE_LOTSTEP);
    return PositionSize;
}

// Prints and writes to file error info and context data.
void Output(string s)
{
    Print(s);
    if (!ErrorLogging) return;
    int file = FileOpen(filename, FILE_CSV | FILE_READ | FILE_WRITE);
    if (file == -1) Print("Failed to create an error log file: ", GetLastError(), ".");
    else
    {
        FileSeek(file, 0, SEEK_END);
        s = TimeToStr(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " - " + s;
        FileWrite(file, s);
        FileClose(file);
    }
}

// Runs only one time to adjust SL to appropriate bar's Low if breakout bar's part outside the pattern turned out to be longer than the one inside.
// Works only if PostEntrySLAdjustment = true.
double AdjustPostBuySL()
{
    double SL = -1;
    string smagic = IntegerToString(Magic);
    double Border;

    // Border.
    if (ObjectFind(UpperBorderLine + smagic) > -1)
    {
        if ((ObjectType(UpperBorderLine + smagic) != OBJ_HLINE) && (ObjectType(UpperBorderLine + smagic) != OBJ_TREND)) return SL;
        // Starting from 1 because it is new bar after breakout bar.
        for (int i = 1; i < Bars; i++)
        {
            if (ObjectType(UpperBorderLine + smagic) != OBJ_HLINE) Border = ObjectGetValueByShift(UpperBorderLine + smagic, i);
            else Border = ObjectGet(UpperBorderLine + smagic, OBJPROP_PRICE1); // Horizontal line value
            // Major part inside pattern but and SL not closer than breakout bar's SL.
            if ((Border - Low[i] > High[i] - Border) && (Low[i] <= Low[1])) return NormalizeDouble(Low[i], Digits);
        }
    }
    else // Try to find a channel.
    {
        if (ObjectFind(BorderChannel + smagic) > -1)
        {
            if (ObjectType(BorderChannel + smagic) != OBJ_CHANNEL) return SL;
            for (int i = 1; i < Bars; i++)
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
    if (ObjectFind(LowerBorderLine + smagic) > -1)
    {
        if ((ObjectType(LowerBorderLine + smagic) != OBJ_HLINE) && (ObjectType(LowerBorderLine + smagic) != OBJ_TREND)) return SL;
        // Starting from 1 because it is new bar after breakout bar.
        for (int i = 1; i < Bars; i++)
        {
            if (ObjectType(LowerBorderLine + smagic) != OBJ_HLINE) Border = ObjectGetValueByShift(LowerBorderLine + smagic, i);
            else Border = ObjectGet(LowerBorderLine + smagic, OBJPROP_PRICE1); // Horizontal line value
            // Major part inside pattern but and SL not closer than breakout bar's SL.
            if ((High[i] - Border > Border - Low[i]) && (High[i] >= High[0])) return NormalizeDouble(High[i], Digits);
        }
    }
    else // Try to find a channel.
    {
        if (ObjectFind(BorderChannel + smagic) > -1)
        {
            if (ObjectType(BorderChannel + smagic) != OBJ_CHANNEL) return SL;
            for (int i = 1; i < Bars; i++)
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
int ExecuteMarketOrder(const int order_type, const double volume, const double price, const double sl, const double tp)
{
    double order_sl = sl;
    double order_tp = tp;

    double StopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
    double FreezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
    double LotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    ENUM_SYMBOL_TRADE_EXECUTION Execution_Mode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_EXEMODE);

    // Market execution mode - preparation.
    if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET)
    {
        // No SL/TP allowed on instant orders.
        order_sl = 0;
        order_tp = 0;
    }

    int ticket = OrderSend(Symbol(), order_type, volume, price, Slippage, order_sl, order_tp, "Chart Pattern Helper", Magic);
    if (ticket == -1)
    {
        int last_error = GetLastError();
        string order_string = "";
        if (order_type == OP_BUY) order_string = "Buy";
        else if (order_type == OP_SELL) order_string = "Sell";
        Output("Error Sending " + order_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
        Output("Volume = " + DoubleToStr(volume, LotStep_digits) + " Entry = " + DoubleToStr(price, Digits) + " SL = " + DoubleToStr(order_sl, Digits) + " TP = " + DoubleToStr(order_tp, Digits));
    }
    else
    {
        Output("Order executed. Ticket: " + IntegerToString(ticket) + ".");
    }

    // Market execution mode - applying SL/TP.
    if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET)
    {
        if (!OrderSelect(ticket, SELECT_BY_TICKET))
        {
            Output("Failed to find the order to apply SL/TP.");
            return 0;
        }
        for (int i = 0; i < 10; i++)
        {
            bool result = OrderModify(ticket, OrderOpenPrice(), sl, tp, OrderExpiration());
            if (result)
            {
                break;
            }
            else
            {
                Output("Error modifying the order: " + IntegerToString(GetLastError()));
            }
        }
    }
    
    return ticket;
}        
//+------------------------------------------------------------------+