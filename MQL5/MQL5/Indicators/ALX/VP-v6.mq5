#property copyright "VP: Volume Profile v6.0. © FXcoder"
#property link      "http://fxcoder.blogspot.com"
#property strict
#property indicator_chart_window
#property indicator_plots 0

#define PUT_IN_RANGE(A, L, H) ((H) < (L) ? (A) : ((A) < (L) ? (L) : ((A) > (H) ? (H) : (A))))
#define COLOR_IS_NONE(C) (((C) >> 24) != 0)
#define RGB_TO_COLOR(R, G, B) ((color)((((B) & 0x0000FF) << 16) + (((G) & 0x0000FF) << 8) + ((R) & 0x0000FF)))
#define ROUND_PRICE(A, P) ((int)((A) / P + 0.5))
#define NORM_PRICE(A, P) (((int)((A) / P + 0.5)) * P)

enum ENUM_POINT_SCALE
{
	POINT_SCALE_1 = 1,      // *1
	POINT_SCALE_10 = 10,    // *10
	POINT_SCALE_100 = 100,  // *100
};

enum ENUM_VP_BAR_STYLE
{
	VP_BAR_STYLE_LINE,        // Line
	VP_BAR_STYLE_BAR,         // Empty bar
	VP_BAR_STYLE_FILLED,      // Filled bar
	VP_BAR_STYLE_OUTLINE,     // Outline
	VP_BAR_STYLE_COLOR        // Color
};

enum ENUM_HG_DIRECTION
{
	HG_DIRECTION_LEFT = 0,   // Right to left
	HG_DIRECTION_RIGHT = 1,  // Left to right
};

enum ENUM_VP_SOURCE
{
	VP_SOURCE_TICKS = 0,   // Ticks

	VP_SOURCE_M1 = 1,      // M1 bars
	VP_SOURCE_M5 = 5,      // M5 bars
	VP_SOURCE_M15 = 15,    // M15 bars
	VP_SOURCE_M30 = 30,    // M30 bars
};

enum ENUM_TIME_SHIFT
{
	TIME_SHIFT_PLUS_720 = 720,     // +12:00
	TIME_SHIFT_PLUS_660 = 660,     // +11:00
	TIME_SHIFT_PLUS_600 = 600,     // +10:00
	TIME_SHIFT_PLUS_540 = 540,     // +9:00
	TIME_SHIFT_PLUS_480 = 480,     // +8:00
	TIME_SHIFT_PLUS_420 = 420,     // +7:00
	TIME_SHIFT_PLUS_360 = 360,     // +6:00
	TIME_SHIFT_PLUS_300 = 300,     // +5:00
	TIME_SHIFT_PLUS_240 = 240,     // +4:00
	TIME_SHIFT_PLUS_180 = 180,     // +3:00
	TIME_SHIFT_PLUS_120 = 120,     // +2:00
	TIME_SHIFT_PLUS_60 = 60,       // +1:00
	TIME_SHIFT_0 = 0,              // 0:00 (no shift)
	TIME_SHIFT_MINUS_60 = -60,     // -1:00
	TIME_SHIFT_MINUS_120 = -120,   // -2:00
	TIME_SHIFT_MINUS_180 = -180,   // -3:00
	TIME_SHIFT_MINUS_240 = -240,   // -4:00
	TIME_SHIFT_MINUS_300 = -300,   // -5:00
	TIME_SHIFT_MINUS_360 = -360,   // -6:00
	TIME_SHIFT_MINUS_420 = -420,   // -7:00
	TIME_SHIFT_MINUS_480 = -480,   // -8:00
	TIME_SHIFT_MINUS_540 = -540,   // -9:00
	TIME_SHIFT_MINUS_600 = -600,   // -10:00
	TIME_SHIFT_MINUS_660 = -660,   // -11:00
	TIME_SHIFT_MINUS_720 = -720,   // -12:00
};

/* Calculation */
input ENUM_TIMEFRAMES RangePeriod = PERIOD_D1;                  // Range period
input int RangeCount = 20;                                      // Range count
input ENUM_TIME_SHIFT TimeShift = TIME_SHIFT_0;                 // Time shift
input int ModeStep = 100;                                       // Mode step (points)
input ENUM_POINT_SCALE HgPointScale = POINT_SCALE_10;           // Point scale
input ENUM_APPLIED_VOLUME VolumeType = VOLUME_TICK;             // Volume type
input ENUM_VP_SOURCE DataSource = VP_SOURCE_M1;                 // Data source

/* Histogram */
input ENUM_VP_BAR_STYLE HgBarStyle = VP_BAR_STYLE_LINE;         // Bar style
input ENUM_HG_DIRECTION DrawDirection = HG_DIRECTION_RIGHT;     // Draw direction
input color HgColor = C'128,160,192';                           // Color 1
input color HgColor2 = C'128,160,192';                          // Color 2
input int HgLineWidth = 1;                                      // Line width

/* Levels */
input color ModeColor = clrBlue;                                // Mode color
input color MaxColor = clrNONE;                                 // Maximum color
input color MedianColor = clrNONE;                              // Median color
input color VwapColor = clrNONE;                                // VWAP color
input int ModeLineWidth = 1;                                    // Mode line width
input ENUM_LINE_STYLE StatLineStyle = STYLE_DOT;                // Median & VWAP line style

/* Service */
input string Id = "+vp";                                        // Identifier
bool ShowHorizon = true;                                  // Show data horizon
double Zoom = 0;                                          // Zoom (0=auto)
int WaitMilliseconds = 1000;                              // Wait milliseconds
uint RangeLength = 0;                                     // Range length (0=Range period) // не реализовано

void OnInit()
{
	_prefix = Id + " " + IntegerToString(RangePeriod) + " ";
	_rangeCount = RangeCount > 0 ? RangeCount : 1;
	_hgPoint = _Point * HgPointScale;
	_modeStep = ModeStep / HgPointScale;

	ArrayFree(_drawHistory);

	// настройки отображения
	_hgBarStyle = HgBarStyle;
	_hgPointDigits = GetPointDigits(_hgPoint);

	_defaultHgColor1 = HgColor;
	_defaultHgColor2 = HgColor2;

	_hgLineWidth = HgLineWidth;

	_modeColor = ModeColor;
	_maxColor = MaxColor;
	_medianColor = MedianColor;
	_vwapColor = VwapColor;
	_modeLineWidth = ModeLineWidth;

	_statLineStyle = StatLineStyle;

	_showHg = !(ColorIsNone(_hgColor1) && ColorIsNone(_hgColor2));
	_showModes = !ColorIsNone(_modeColor);
	_showMax = !ColorIsNone(_maxColor);
	_showMedian = !ColorIsNone(_medianColor);
	_showVwap = !ColorIsNone(_vwapColor);

	_zoom = MathAbs(Zoom);
	_updateTimer = new MillisecondTimer(WaitMilliseconds, false);

	// сдвиг не может быть больше RangePeriod
	_timeShiftSeconds = (((int)TimeShift * 60) % PeriodSeconds(RangePeriod));

	// коррекция сдвига вперёд, если он отрицательный, чтобы рисовался и последний диапазон
	if (_timeShiftSeconds < 0)
		_timeShiftSeconds += PeriodSeconds(RangePeriod);

	// таймфрейм источника данных
	_dataPeriod = GetDataPeriod(DataSource);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{

	if (id == CHARTEVENT_CHART_CHANGE)
	{
		// если цвет фона изменился, перерисовать все гистограммы
		if (UpdateAutoColors())
		{
			ArrayFree(_drawHistory);
			CheckTimer();
		}
	}
}

int OnCalculate(const int ratesTotal, const int prevCalculated, const datetime &time[], const double &open[], const double &high[], const double &low[], const double &close[], const long &tickVolume[], const long &volume[], const int &spread[])
{

	// если цвет фона изменился, перерисовать все гистограммы
	if (UpdateAutoColors())
		ArrayFree(_drawHistory);

	CheckTimer();
	return(0);
}

void OnTimer()
{

	CheckTimer();
}

void OnDeinit(const int reason)
{
	ObjectsDeleteAll(0, _prefix);
	delete(_updateTimer);
}

void CheckTimer()
{
	// Выключить резервный таймер
	EventKillTimer();

	// Если таймер сработал, нарисовать картинку. Либо сразу, если в прошлый раз была проблема.
	if (_updateTimer.Check() || !_lastOK)
	{
		// Обновить. В случае неудачи поставить таймер на 3 секунды, чтобы попробовать снова ещё раз.
		// 3 секунды должно быть достаточно для подгрузки последней истории. Иначе всё просто повторится ещё через 3.
		_lastOK = Update();

		if (!_lastOK)
			EventSetTimer(3);

		ChartRedraw();

		// расчёт и рисование могут быть длительными, лучше перезапустить таймер
		_updateTimer.Reset();
	}
	else
	{
		// На случай, если свой таймер больше не будет проверяться, добавить принудительную проверку через 3 секунды
		EventSetTimer(3);
	}
}

bool Update()
{
	// Составить список диапазонов
	datetime ranges[];
	ArraySetAsSeries(ranges, true);
	ArrayResize(ranges, _rangeCount);

	if (CopyTime(_Symbol, RangePeriod, 0, _rangeCount, ranges) != _rangeCount)
		return(false);

	// Если RangePeriod - неделя, сдвинуть всё вперёд на 1 день, т.к. неделя в MT начинается с воскресенья
	if (RangePeriod == PERIOD_W1)
	{
		for (int i = 0; i < _rangeCount; i++)
			ranges[i] += 1440 * 60;
	}

	/* Проверить наличие необходимых котировок. */
	int rangeLengthSeconds = RangeLength == 0 ? PeriodSeconds(RangePeriod) : (int)RangeLength * 60;

	datetime dataRates[];
	datetime rangesStart = ranges[_rangeCount - 1] + _timeShiftSeconds;
	datetime rangesEnd = ranges[0] + rangeLengthSeconds - 1 + _timeShiftSeconds;

	if (CopyTime(_Symbol, _dataPeriod, rangesStart, rangesEnd, dataRates) <= 0)
		return(false);

	// время текущего бара
	MqlTick tick;
	if (!SymbolInfoTick(_Symbol, tick))
		return(false);

	datetime lastTickTime = tick.time;

	if (ShowHorizon)
	{
		datetime horizon = GetHorizon(DataSource, _dataPeriod);
		DrawHorizon(_prefix + "hz", horizon);
	}

	int modes[];
	double volumes[];
	double lowPrice;

	bool totalResult = true;

	for (int i = 0; i < _rangeCount; i++)
	{
		/* Расчёт */

		// Границы диапазона
		datetime rangeStart = ranges[i] + _timeShiftSeconds;

		if (TimeDayOfWeek(rangeStart) == SUNDAY)
			rangeStart -= 2 * 1440 * 60;

		// Если гистограмма уже была успешно нарисована, пропустить. Кроме крайней правой.
		if ((i != 0) && (ArrayIndexOf(_drawHistory, rangeStart) != -1))
			continue;

		// конец диапазона с учётом сдвига
		datetime rangeEnd;

		if (i == 0)
		{
			rangeEnd = ranges[i] + _timeShiftSeconds + rangeLengthSeconds - 1;
		}
		else
		{
			rangeEnd = ranges[i - 1] + _timeShiftSeconds - 1;

			if (TimeDayOfWeek(rangeEnd) == SUNDAY)
				rangeEnd -= 2 * 1440 * 60;
		}

		int barFrom, barTo;

		if (!GetRangeBars(rangeStart, rangeEnd, barFrom, barTo))
		{
			totalResult = false;
			// в случае ошибки рисования одной гистограммы, продолжить рисовать другие
			continue;
		}

		int count;

		if (DataSource == VP_SOURCE_TICKS)
			count = GetHgByTicks(rangeStart, rangeEnd, _hgPoint, _dataPeriod, VolumeType, lowPrice, volumes);
		else
			count = GetHg(rangeStart, rangeEnd, _hgPoint, _dataPeriod, VolumeType, lowPrice, volumes);

		if (count <= 0)
		{
			totalResult = false;
			// в случае ошибки рисования одной гистограммы, продолжить рисовать другие
			continue;
		}

		// добавить гистограмму в список выполненных, если её правая граница левее текущего тика
		if (rangeEnd < lastTickTime)
			ArrayAdd(_drawHistory, rangeStart, true);

		/* Отображение */

		// Уровни
		int modeCount = _showModes ? HgModes(volumes, _modeStep, modes) : -1;
		int maxPos = _showMax ? ArrayMax(volumes) : -1;
		int medianPos = _showMedian ? ArrayMedian(volumes) : -1;
		int vwapPos = _showVwap ? HgVwap(volumes, lowPrice, _hgPoint) : -1;

		// префикс для каждой гистограммы свой
		string prefix = _prefix + (string)((int)rangeStart / PeriodSeconds(RangePeriod)) + " ";

		double maxVolume = volumes[ArrayMaximum(volumes)];

		// Учесть нулевые объёмамы всех баров источника
		if (maxVolume == 0)
			maxVolume = 1;

		// определить масштаб и направление
		double zoom = _zoom > 0 ? _zoom : (barFrom - barTo) / maxVolume;

		if (DrawDirection == HG_DIRECTION_LEFT)
			Swap(barFrom, barTo);

		// Удалить старые линии
		ObjectsDeleteAll(0, prefix);

		// Отобразить гистограмму
		DrawHg(prefix, lowPrice, volumes, barFrom, barTo, zoom, modes, maxPos, medianPos, vwapPos);
	}

	return(totalResult);
}

ENUM_DAY_OF_WEEK TimeDayOfWeek(const datetime time)
{
	MqlDateTime timeStruct;
	TimeToStruct(time, timeStruct);
	return (ENUM_DAY_OF_WEEK)timeStruct.day_of_week;
}

template <typename T>
int ArrayIndexOf(const T &arr[], const T value, const int startingFrom = 0)
{
	int size = ArraySize(arr);

	for (int i = startingFrom; i < size; i++)
	{
		if (arr[i] == value)
			return(i);
	}

	return(-1);
}

template <typename T>
int ArrayAdd(T &arr[], T value, const bool checkUnique = false, const int reserveSize = 100)
{
	int i;

	// Найти существующий, если необходимо
	if (checkUnique)
	{
		i = ArrayIndexOf(arr, value);

		if (i != -1)
			return(i);
	}

	// Добавить новый элемент в массив
	i = ArrayResize(arr, ArraySize(arr) + 1, reserveSize);

	if (i == -1)
		return(-1);

	i--;
	arr[i] = value;

	return(i);
}

template <typename T>
bool ArrayCheckRange(const T &arr[], int &start, int &count)
{
	int size = ArraySize(arr);

	// в случае пустого массива результат неопределён, но вернуть как ошибочный
	if (size <= 0)
		return(false);

	// в случае нулевого диапазона результат неопределён, но вернуть как ошибочный
	if (count == 0)
		return(false);

	// старт выходит за границы массива
	if ((start > size - 1) || (start < 0))
		return(false);

	if (count < 0)
	{
		// если количество не указано, вернуть всё от start
		count = size - start;
	}
	else if (count > size - start)
	{
		// если элементов недостаточно для указанного количества, вернуть максимально возможное
		count = size - start;
	}

	return(true);
}

int ArrayMedian(const double &values[])
{
	int size = ArraySize(values);
	double halfVolume = Sum(values) / 2.0;

	double v = 0;

	// пройти по гистограмме и остановиться на середине по объёму
	for (int i = 0; i < size; i++)
	{
		v += values[i];

		if (v >= halfVolume)
			return(i);
	}

	return(-1);
}

string TrimRight(string s, const ushort ch)
{
	int len = StringLen(s);

	// Найти начало вырезаемого до конца участка
	int cut = len;

	for (int i = len - 1; i >= 0; i--)
	{
		if (StringGetCharacter(s, i) == ch)
			cut--;
		else
			break;
	}

	if (cut != len)
	{
		if (cut == 0)
			s = "";
		else
			s = StringSubstr(s, 0, cut);
	}

	return(s);
}

string DoubleToString(const double d, const uint digits, const uchar separator)
{
	string s = DoubleToString(d, digits) + ""; //HACK: без +"" функция может вернуть пустое значение (билд 697)

	if (separator != '.')
	{
		int p = StringFind(s, ".");

		if (p != -1)
			StringSetCharacter(s, p, separator);
	}

	return(s);
}

string DoubleToCompactString(const double d, const uint digits = 8, const uchar separator = '.')
{
	string s = DoubleToString(d, digits, separator);

	// убрать нули в конце дробной части
	if (StringFind(s, CharToString(separator)) != -1)
	{
		s = TrimRight(s, '0');
		s = TrimRight(s, '.');
	}

	return(s);
}

double MathRound(const double value, const double error)
{
	return(error == 0 ? value : MathRound(value / error) * error);
}

template <typename T>
void Swap(T &value1, T &value2)
{
	T tmp = value1;
	value1 = value2;
	value2 = tmp;
}

template <typename T>
T Sum(const T &arr[], int start = 0, int count = -1)
{
	if (!ArrayCheckRange(arr, start, count))
		return((T)NULL);

	T sum = (T)NULL;

	for (int i = start, end = start + count; i < end; i++)
		sum += arr[i];

	return(sum);
}

int GetPointDigits(const double point)
{
	if (point == 0)
		return(_Digits);

	return(GetPointDigits(point, _Digits));
}

int GetPointDigits(const double point, const int maxDigits)
{
	if (point == 0)
		return(maxDigits);

	string pointString = DoubleToCompactString(point, maxDigits);
	int pointStringLen = StringLen(pointString);
	int dotPos = StringFind(pointString, ".");

	// pointString => result:
	//   1230   => -1
	//   123    =>  0
	//   12.3   =>  1
	//   1.23   =>  2
	//   0.123  =>  3
	//   .123   =>  3

	return(dotPos < 0
		? StringLen(TrimRight(pointString, '0')) - pointStringLen
		: pointStringLen - dotPos - 1);
}

template <typename T>
int ArrayMax(const T &array[], const int start = 0, const int count = WHOLE_ARRAY)
{
	return(ArrayMaximum(array, start, count));
}

int HgModes(const double &values[], const int modeStep, int &modes[])
{
	int modeCount = 0;
	ArrayFree(modes);

	// ищем максимумы по участкам
	for (int i = modeStep, count = ArraySize(values) - modeStep; i < count; i++)
	{
		int maxFrom = i - modeStep;
		int maxRange = 2 * modeStep + 1;
		int maxTo = maxFrom + maxRange - 1;

		int k = ArrayMax(values, maxFrom, maxRange);

		if (k != i)
			continue;

		for (int j = i - modeStep; j <= i + modeStep; j++)
		{
			if (values[j] != values[k])
				continue;

			modeCount++;
			ArrayResize(modes, modeCount, count);
			modes[modeCount - 1] = j;
		}
	}

	return(modeCount);
}

int HgVwap(const double &volumes[], const double low, const double step)
{
	if (step == 0)
		return(-1);

	double vwap = 0;
	double totalVolume = 0;
	int size = ArraySize(volumes);

	for (int i = 0; i < size; i++)
	{
		double price = low + i * step;
		double volume = volumes[i];

		vwap += price * volume;
		totalVolume += volume;
	}

	if (totalVolume == 0)
		return(-1);

	vwap /= totalVolume;
	return((int)((vwap - low) / step + 0.5));
}

int iBarShift(string symbol, ENUM_TIMEFRAMES timeframe, datetime time, bool exact = false)
{
	if (time < 0)
		return(-1);

	datetime arr[];
	datetime time1;
	CopyTime(symbol, timeframe, 0, 1, arr);
	time1 = arr[0];

	if (CopyTime(symbol, timeframe, time, time1, arr) <= 0)
		return(-1);

	if (ArraySize(arr) > 2)
		return(ArraySize(arr) - 1);

	return(time < time1 ? 1 : 0);
}

datetime iTime(string symbol, ENUM_TIMEFRAMES timeframe, int index)
{
	if (index < 0)
		return(-1);

	datetime arr[];

	if (CopyTime(symbol, timeframe, index, 1, arr)<= 0)
		return(-1);

	return(arr[0]);
}

// получить (вычислить) гистограмму по тикам
int GetHgByTicks(const datetime timeFrom, const datetime timeTo, const double point, const ENUM_TIMEFRAMES dataPeriod, const ENUM_APPLIED_VOLUME appliedVolume, double &low, double &volumes[])
{
	// Определить количество тиков по суммарному тиковому объёму баров диапазона
	long tickVolumes[];
	int tickVolumeCount = CopyTickVolume(_Symbol, dataPeriod, timeFrom, timeTo, tickVolumes);

	if (tickVolumeCount <= 0)
		return(0);

	long tickVolumesTotal = Sum(tickVolumes);

	// Скопировать тики, нужны только совершённые сделки, нужна информаци только по Last + объём + время тика
	MqlTick ticks[];
	int tickCount = CopyTicks(_Symbol, ticks, COPY_TICKS_TRADE, timeFrom * 1000, (uint)tickVolumesTotal);

	// Нет тиков - нет гистограммы
	if (tickCount <= 0)
	{
		return(0);
	}

	// Определить минимум и максимум, размер массива гистограммы
	MqlTick tick = ticks[0];
	low = NORM_PRICE(tick.last, point);
	double high = low;
	long timeToMs = timeTo * 1000;

	for (int i = 1; i < tickCount; i++)
	{
		tick = ticks[i];

		// Иногда полученные тики выходят за указанный диапазон (ошибка в данных на сервере, например).
		// В таком случае обрезать лишнее. Сам массив можно не изменять, достаточно уточнить количество правильных тиков.
		// Предположительно проблемы выхода за левую границу нет.
		if (tick.time_msc > timeToMs)
		{
			tickCount = i;
			break;
		}

		double tickLast = NORM_PRICE(tick.last, point);

		if (tickLast < low)
			low = tickLast;

		if (tickLast > high)
			high = tickLast;
	}

	int lowIndex = ROUND_PRICE(low, point);
	int highIndex = ROUND_PRICE(high, point);
	int hgSize = highIndex - lowIndex + 1; // количество цен в гистограмме
	ArrayResize(volumes, hgSize);
	ArrayInitialize(volumes, 0);

	// Сложить все тики в одну гистограмму

	int pri;

	for (int j = 0; j < tickCount; j++)
	{
		tick = ticks[j];
		pri = ROUND_PRICE(tick.last, point) - lowIndex;

		// Если нужен реальный объём, берём его из информации по тику.
		// Если нужен тиковый объём, то достаточно учесть каждый тик ровно один раз.
		volumes[pri] += (appliedVolume == VOLUME_REAL) ? (double)tick.volume : 1;
	}

	return(hgSize);
}

// получить (вычислить) гистограмму по барам, имитируя тики
int GetHg(const datetime timeFrom, const datetime timeTo, const double point, const ENUM_TIMEFRAMES dataPeriod, const ENUM_APPLIED_VOLUME appliedVolume, double &low, double &volumes[])
{
	// Получить бары таймфрейма расчёта (обычно M1)
	MqlRates rates[];
	int rateCount = CopyRates(_Symbol, dataPeriod, timeFrom, timeTo, rates);

	if (rateCount <= 0)
		return(0);

	// Определить минимум и максимум, размер массива гистограммы
	MqlRates rate = rates[0];
	low = NORM_PRICE(rate.low, point);
	double high = NORM_PRICE(rate.high, point);

	for (int i = 1; i < rateCount; i++)
	{
		rate = rates[i];

		double rateHigh =  NORM_PRICE(rate.high, point);
		double rateLow = NORM_PRICE(rate.low, point);

		if (rateLow < low)
			low = rateLow;

		if (rateHigh > high)
			high = rateHigh;
	}

	int lowIndex = ROUND_PRICE(low, point);
	int highIndex = ROUND_PRICE(high, point);
	int hgSize = highIndex - lowIndex + 1; // количество цен в гистограмме
	ArrayResize(volumes, hgSize);
	ArrayInitialize(volumes, 0);

	// Сложить все тики всех баров в одну гистограмму

	int pri, oi, hi, li, ci;
	double dv, v;

	for (int j = 0; j < rateCount; j++)
	{
		rate = rates[j];

		oi = ROUND_PRICE(rate.open, point) - lowIndex;
		hi = ROUND_PRICE(rate.high, point) - lowIndex;
		li = ROUND_PRICE(rate.low, point) - lowIndex;
		ci = ROUND_PRICE(rate.close, point) - lowIndex;

		v = (appliedVolume == VOLUME_REAL) ? (double)rate.real_volume : (double)rate.tick_volume;

		// имитация тиков внутри бара
		if (ci >= oi)
		{
			/* бычья свеча */

			// средний объём каждого тика
			dv = v / (oi - li + hi - li + hi - ci + 1.0);

			// open --> low
			for (pri = oi; pri >= li; pri--)
				volumes[pri] += dv;

			// low+1 ++> high
			for (pri = li + 1; pri <= hi; pri++)
				volumes[pri] += dv;

			// high-1 --> close
			for (pri = hi - 1; pri >= ci; pri--)
				volumes[pri] += dv;
		}
		else
		{
			/* медвежья свеча */

			// средний объём каждого тика
			dv = v / (hi - oi + hi - li + ci - li + 1.0);

			// open ++> high
			for (pri = oi; pri <= hi; pri++)
				volumes[pri] += dv;

			// high-1 --> low
			for (pri = hi - 1; pri >= li; pri--)
				volumes[pri] += dv;

			// low+1 ++> close
			for (pri = li + 1; pri <= ci; pri++)
				volumes[pri] += dv;
		}
	}

	return(hgSize);
}

// Получить время первых доступных данных
datetime GetHorizon(ENUM_VP_SOURCE dataSource, ENUM_TIMEFRAMES dataPeriod)
{
	if (dataSource == VP_SOURCE_TICKS)
	{
		MqlTick ticks[];
		int tickCount = CopyTicks(_Symbol, ticks, COPY_TICKS_INFO, 1, 1);

		if (tickCount <= 0)
			return ((datetime)(SymbolInfoInteger(_Symbol, SYMBOL_TIME) + 1));

		return(ticks[0].time);
	}

	return((datetime)(iTime(_Symbol, dataPeriod, Bars(_Symbol, dataPeriod) - 1)));
}

// Получить таймфрейм источника данных
ENUM_TIMEFRAMES GetDataPeriod(ENUM_VP_SOURCE dataSource)
{
	switch (dataSource)
	{
		case VP_SOURCE_TICKS: return(PERIOD_M1); // для получения числа необходимых для загрузки тиков

		case VP_SOURCE_M1:    return(PERIOD_M1);
		case VP_SOURCE_M5:    return(PERIOD_M5);
		case VP_SOURCE_M15:   return(PERIOD_M15);
		case VP_SOURCE_M30:   return(PERIOD_M30);
		default:              return(PERIOD_M1);
	}
}

bool ColorToRGB(const color c, int &r, int &g, int &b)
{
	// Если цвет задан неверный, либо задан как отсутствующий, вернуть false
	if (COLOR_IS_NONE(c))
		return(false);

	b = (c & 0xFF0000) >> 16;
	g = (c & 0x00FF00) >> 8;
	r = (c & 0x0000FF);

	return(true);
}

color MixColors(const color color1, const color color2, double mix, double step = 16)
{
	// Коррекция неверных параметров
	step = PUT_IN_RANGE(step, 1.0, 255.0);
	mix = PUT_IN_RANGE(mix, 0.0, 1.0);

	int r1, g1, b1;
	int r2, g2, b2;

	// Разбить на компоненты
	ColorToRGB(color1, r1, g1, b1);
	ColorToRGB(color2, r2, g2, b2);

	// вычислить
	int r = PUT_IN_RANGE((int)MathRound(r1 + mix * (r2 - r1), step), 0, 255);
	int g = PUT_IN_RANGE((int)MathRound(g1 + mix * (g2 - g1), step), 0, 255);
	int b = PUT_IN_RANGE((int)MathRound(b1 + mix * (b2 - b1), step), 0, 255);

	return(RGB_TO_COLOR(r, g, b));
}

bool ColorIsNone(const color c)
{
	return(COLOR_IS_NONE(c));
}

class MillisecondTimer
{
	private: int _milliseconds;
	private: uint _lastTick;

	public: void MillisecondTimer(const int milliseconds, const bool reset = true)
	{
		_milliseconds = milliseconds;

		if (reset)
			Reset();
		else
			_lastTick = 0;
	}

	public: bool Check()
	{
		// проверить ожидание
		uint now = getCurrentTick();
		bool stop = now >= _lastTick + _milliseconds;

		// сбрасываем таймер
		if (stop)
			_lastTick = now;

		return(stop);
	}

	public: void Reset()
	{
		_lastTick = getCurrentTick();
	}

	private: uint getCurrentTick() const
	{
		return(GetTickCount());
	}

};

void ObjectDisable(const long chartId, const string name)
{
	ObjectSetInteger(chartId, name, OBJPROP_HIDDEN, true);
	ObjectSetInteger(chartId, name, OBJPROP_SELECTABLE, false);
}

int GetTimeBarRight(datetime time, ENUM_TIMEFRAMES period = PERIOD_CURRENT)
{
	int bar = iBarShift(_Symbol, period, time);
	datetime t = iTime(_Symbol, period, bar);

	if ((t != time) && (bar == 0))
	{
		// время за пределами диапазона
		bar = (int)((iTime(_Symbol, period, 0) - time) / PeriodSeconds(period));
	}
	else
	{
		// проверить, чтобы бар был не слева по времени
		if (t < time)
			bar--;
	}

	return(bar);
}

// получить время по номеру бара с учетом возможного выхода за диапазон баров (номер бара меньше 0)
datetime GetBarTime(const int shift, ENUM_TIMEFRAMES period = PERIOD_CURRENT)
{
	if (shift >= 0)
		return(iTime(_Symbol, period, shift));
	else
		return(iTime(_Symbol, period, 0) - shift * PeriodSeconds(period));
}

// нарисовать линию горизонта данных
void DrawHorizon(const string lineName, const datetime time)
{
	DrawVLine(lineName, time, Red, 1, STYLE_DOT, false);
	ObjectDisable(0, lineName);
}

// нарисовать вертикальную линию
void DrawVLine(const string name, const datetime time1, const color lineColor, const int width, const int style, const bool back)
{
	if (ObjectFind(0, name) >= 0)
		ObjectDelete(0, name);

	ObjectCreate(0, name, OBJ_VLINE, 0, time1, 0);
	ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
	ObjectSetInteger(0, name, OBJPROP_BACK, back);
	ObjectSetInteger(0, name, OBJPROP_STYLE, style);
	ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
}

// нарисовать бар гистограммы
void DrawBar(const string name, const datetime time1, const datetime time2, const double price,
	const color lineColor, const int width, const ENUM_VP_BAR_STYLE barStyle, const ENUM_LINE_STYLE lineStyle, bool back)
{
	ObjectDelete(0, name);

	if (barStyle == VP_BAR_STYLE_BAR)
	{
		ObjectCreate(0, name, OBJ_RECTANGLE, 0, time1, price - _hgPoint / 2.0, time2, price + _hgPoint / 2.0);

	}
	else if ((barStyle == VP_BAR_STYLE_FILLED) || (barStyle == VP_BAR_STYLE_COLOR))
	{
		ObjectCreate(0, name, OBJ_RECTANGLE, 0, time1, price - _hgPoint / 2.0, time2, price + _hgPoint / 2.0);
	}
	else if (barStyle == VP_BAR_STYLE_OUTLINE)
	{
		ObjectCreate(0, name, OBJ_TREND, 0, time1, price, time2, price + _hgPoint);
	}
	else
	{
		ObjectCreate(0, name, OBJ_TREND, 0, time1, price, time2, price);
	}

	SetBarStyle(name, lineColor, width, barStyle, lineStyle, back);
}

// установить стиль бара
void SetBarStyle(const string name, const color lineColor, const int width, const ENUM_VP_BAR_STYLE barStyle, const ENUM_LINE_STYLE lineStyle, bool back)
{
	ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
	ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
	ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
	ObjectSetInteger(0, name, OBJPROP_STYLE, lineStyle);
	ObjectSetInteger(0, name, OBJPROP_WIDTH, lineStyle == STYLE_SOLID ? width : 1);

	ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
	ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);

	ObjectSetInteger(0, name, OBJPROP_BACK, back);
	ObjectSetInteger(0, name, OBJPROP_FILL, (barStyle == VP_BAR_STYLE_FILLED) || (barStyle == VP_BAR_STYLE_COLOR));
}

// нарисовать уровень
void DrawLevel(const string name, const double price)
{
	ObjectDelete(0, name);
	ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);

	ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
	ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
	ObjectSetInteger(0, name, OBJPROP_COLOR, _modeLevelColor);
	ObjectSetInteger(0, name, OBJPROP_STYLE, _modeLevelStyle);
	ObjectSetInteger(0, name, OBJPROP_WIDTH, _modeLevelStyle== STYLE_SOLID ? _modeLevelWidth : 1);

	// не должен быть фоном, иначе не будет отображена цена справа
	ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

// нарисовать гистограмму
void DrawHg(const string prefix, const double lowPrice, const double &volumes[], const int barFrom, const int barTo,
	double zoom, const int &modes[], const int max = -1, const int median = -1, const int vwap = -1)
{
	if (ArraySize(volumes) == 0)
		return;

	if (barFrom > barTo)
		zoom = -zoom;

	color cl = _hgColor1;
	double maxValue = volumes[ArrayMaximum(volumes)];

	// Учесть возможность нулевых значений всех баров
	if (maxValue == 0)
		maxValue = 1;

	double volume;
	double nextVolume = 0;
	bool isOutline = _hgBarStyle == VP_BAR_STYLE_OUTLINE;

	int bar1 = barFrom;
	int bar2 = barTo;
	int modeBar2 = barTo;

	for (int i = 0, size = ArraySize(volumes); i < size; i++)
	{
		double price = NormalizeDouble(lowPrice + i * _hgPoint, _hgPointDigits);
		string priceString = DoubleToString(price, _hgPointDigits);
		string name = prefix + priceString;
		volume = volumes[i];

		if (isOutline)
		{
			if (i < size - 1)
			{
				nextVolume = volumes[i + 1];
				bar1 = (int)(barFrom + volume * zoom);
				bar2 = (int)(barFrom + nextVolume * zoom);
				modeBar2 = bar1;
			}
		}
		else if (_hgBarStyle != VP_BAR_STYLE_COLOR)
		{
			bar2 = (int)(barFrom + volume * zoom);
			modeBar2 = bar2;
		}

		datetime timeFrom = GetBarTime(barFrom);
		datetime timeTo = GetBarTime(barTo);
		datetime t1 = GetBarTime(bar1);
		datetime t2 = GetBarTime(bar2);
		datetime mt2 = GetBarTime(modeBar2);

		// При совпадении нескольких уровней рисовать только один в приоритете: max, median, vwap, mode.
		// Если ничего не совпадает, нарисовать обычный бар.

		if (_showModeLevel && (ArrayIndexOf(modes, i) != -1))
			DrawLevel(name + " level", price);

		// В режиме контура последний бар не рисуется
		if (_showHg && !(isOutline && (i == size - 1)))
		{
			if (_hgColor1 != _hgColor2)
				cl = MixColors(_hgColor1, _hgColor2, (isOutline ? MathMax(volume, nextVolume) : volume) / maxValue, 8);

			DrawBar(name, t1, t2, price, cl, _hgLineWidth, _hgBarStyle, STYLE_SOLID, true);
		}

		if (_showMedian && (i == median))
		{
			DrawBar(name + " median", timeFrom, timeTo, price, _medianColor, _modeLineWidth, VP_BAR_STYLE_LINE, _statLineStyle, false);
		}
		else if (_showVwap && (i == vwap))
		{
			DrawBar(name + " vwap", timeFrom, timeTo, price, _vwapColor, _modeLineWidth, VP_BAR_STYLE_LINE, _statLineStyle, false);
		}
		else if ((_showMax && (i == max)) || (_showModes && (ArrayIndexOf(modes, i) != -1)))
		{
			color modeColor = (_showMax && (i == max)) ? _maxColor : _modeColor;

			if (_hgBarStyle == VP_BAR_STYLE_LINE)
				DrawBar(name, timeFrom, mt2, price, modeColor, _modeLineWidth, VP_BAR_STYLE_LINE, STYLE_SOLID, false);
			else if (_hgBarStyle == VP_BAR_STYLE_BAR)
				DrawBar(name, timeFrom, mt2, price, modeColor, _modeLineWidth, VP_BAR_STYLE_BAR, STYLE_SOLID, false);
			else if (_hgBarStyle == VP_BAR_STYLE_FILLED)
				DrawBar(name, timeFrom, mt2, price, modeColor, _modeLineWidth, VP_BAR_STYLE_FILLED, STYLE_SOLID, false);
			else if (_hgBarStyle == VP_BAR_STYLE_OUTLINE)
				DrawBar(name + "+", timeFrom, mt2, price, modeColor, _modeLineWidth, VP_BAR_STYLE_LINE, STYLE_SOLID, false);
			else if (_hgBarStyle == VP_BAR_STYLE_COLOR)
				DrawBar(name, timeFrom, mt2, price, modeColor, _modeLineWidth, VP_BAR_STYLE_FILLED, STYLE_SOLID, false);
		}
	}
}

// получить диапазон баров в текущем ТФ (для рисования)
bool GetRangeBars(const datetime timeFrom, const datetime timeTo, int &barFrom, int &barTo)
{
	barFrom = GetTimeBarRight(timeFrom);
	barTo = GetTimeBarRight(timeTo);
	return(true);
}

// Обновить цвета, вычисляемые автоматически. Если обновление произошло, вернуть true, иначе false
bool UpdateAutoColors()
{
	if (!_showHg)
		return(false);

	bool isNone1 = ColorIsNone(_defaultHgColor1);
	bool isNone2 = ColorIsNone(_defaultHgColor2);

	if (isNone1 && isNone2)
		return(false);

	color newBgColor = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

	if (newBgColor == _prevBackgroundColor)
		return(false);

	_hgColor1 = isNone1 ? newBgColor : _defaultHgColor1;
	_hgColor2 = isNone2 ? newBgColor : _defaultHgColor2;

	_prevBackgroundColor = newBgColor;
	return(true);
}

string _prefix;
string _tfn;
string _ttn;

// история рисования
datetime _drawHistory[];
// последний запуск успешный
bool _lastOK = false;

// минимальное изменение цены для отображения гг
int _modeStep = 0;

color _prevBackgroundColor = clrNONE;

int _rangeCount;

ENUM_VP_BAR_STYLE _hgBarStyle;
double _hgPoint;
int _hgPointDigits;

color _defaultHgColor1;
color _defaultHgColor2;
color _hgColor1;
color _hgColor2;
int _hgLineWidth;

color _modeColor;
color _maxColor;
color _medianColor;
color _vwapColor;
int _modeLineWidth;

ENUM_LINE_STYLE _statLineStyle;

color _modeLevelColor;
ENUM_LINE_STYLE _modeLevelStyle;
int _modeLevelWidth;

bool _showHg;
bool _showModes;
bool _showMax;
bool _showMedian;
bool _showVwap;
bool _showModeLevel;

double _zoom;

int _firstVisibleBar = 0;
int _lastVisibleBar = 0;

MillisecondTimer *_updateTimer;

bool _isTimeframeEnabled = false;

int _timeShiftSeconds = 0;
ENUM_TIMEFRAMES _dataPeriod;

/*

Список измненений

6.0
	* добавлено: новый параметр "Data source" для указания источника данных - таймфреймы M1, M5, M15 или (только в MT5) тики.
	* изменено: параметр "Point scale" перенесён выше в списке параметров
	* изменено: параметр "Bar style" перенесён выше в списке параметров

5.8
	* исправлено: гистограмма не отображается, если есть хотя бы один бар с нулевым объёмом на таймфрейме источника данных

5.7
	* VP:
		* исправлено: при "Range period" = "1 Week" гистограммы смещались на день влево

5.6
	* VP-Range:
		* исправлено: не обновляется гистограмма в режиме "Last minutes"
		* исправлено: не учитывается последняя минута в режиме "Last minutes"

5.5
	* изменены ссылки на сайт
	* список изменений в коде

5.4
	* исправлена медиана в MT4

5.3
	* исправлено: в MT4 при рисовании пустыми прямоугольниками плохо было видно моды из-за наложения баров
	* стиль баров по умолчанию изменён на линии

5.2
	* VP-Range:
		* исправлено: в режиме "Minutes to line" не выделяется правая граница, но выделяется левая, должно быть наоборот
		* исправлено: после переключения режима с "Minutes to line" на "Between lines" не выделяется одна из границ

5.1
	* исправлено игнорирование отображения на определённых таймфремах в MT4 (обход бага в MT4)

5.0
	* увеличены таймауты перерисовки для снижения нагрузки
	* только VP:
		* временной сдвиг от -12 до +12 часов с шагом 1 час для компенсации сдвига часового пояса у брокера
		* по умолчанию медиана и VWAP выключены

4.0
	* индикатор переименован на VP (сокращение от Volume Profile)
	* добавлена версия для MetaTrader 5 с минимальными отличиями в коде от версии для MetaTrader 4
	* добавлено: второй цвет гистограммы для рисования градиентом
	* добавлено: типы гистограмм Outline (контур) и Color (цвет)
	* добавлено: уровни VWAP (средневзвешенная по объёму цена) и Median (медиана)
	* добавлено: ручное указание масштаба пункта
	* добавлено: VP-Range: расположение гистограммы внутри диапазона
	* добавлено: VP: отображение гистограмм справа налево
	* изменено: Mode step теперь следует указывать в 10 раз больше для того же результата, это сделано для большей точности на небольших диапазонах
	* изменено: VP: данные последнего бара теперь учитываются
	* изменено: VP-Range: в режимах отображения от границ окна и границ диапазона наружу ширина гистограммы увеличена с 10% до 15% от размеров графика, в остальных случаях (внутри границ диапазона) ширина равна ширине диапазона

3.2
	* исправлено: при открытии на графике без истории появляется ошибка "...array out of range in..."
	* изменено: линия горизонта спрятана из списка объектов и отключена для выбора

3.1
	* исправлено: при обновлении по последним данным могут оставаться старые моды и максимумы
	* добавлено: TPO-Range теперь обновляется сразу после перемещения границ в соответствущих режимах

3.0
	* скрыты недокументированные параметры DataPeriod и PriceStep (были показаны по ошибке)
	* использование новых возможностей MetaTrader 4 и оптимизация под него:
		* улучшены отображаемые названия параметров
		* перечисляемые параметры (режимы, стили, периоды) реализованы в виде списков выбора, их числовые значения остались прежними
		* линии гистограмм нельзя выбрать мышкой (не мешаются среди других индикаторов и разметки)
		* оптимизация после изменений в работе функции ArrayCopyRates()
		* поддержка реальных объемов, если они доступны
	* исправлен параметр ModeStep, теперь он лучше реагирует на изменения
	* удаление за собой линий диапазона в TPO-Range, в одном из предыдущих обновлений MetaTrader исправлена ошибка, мешающая делать это
	* удалена скрытая поддержка нескольких методов имитации тиков, оставлен только наиболее точный
	* в режиме 1 (Last minutes) TPO-Range линии выбора/отображения диапазона больше не показываются

2.6
	* совместимость с MetaTrader версии 4.00 Build 600 и новее

2.5.7491
	* в некоторых режимах в стиле по умолчанию (HGStyle=1) при сжатии графика по вертикали исчезает изображение локальных максимумов
	* удалено из-за ошибки в МТ: TPO-Range - при удалении индикатора удаляются и линии границ (было добавлено в 2.4.7290)

2.5.7484
	* в стиле по умолчанию (HGStyle=1) при сжатии графика по вертикали исчезает изображение локальных максимумов

2.5.7473
	* названия индикаторов изменены в соответствии с распространённым названием методики расчёта, схожей с данной
	* добавлен параметр HGStyle: 0 - рисовать линиями, 1 - рисовать пустыми прямоугольниками (значение по умолчанию), 2 - обычные прямоугольники (режим полезен при наложении нескольких индикаторов TPO друг на друга)

2.4.7290
	* исправлено: не удаляются старые моды при использовании на меняющихся данных
	* из набора исключён скрипт +FindVL
	* исправлено: при включенной максимальной моде и отключенных остальных показываются все
	* +VL - при удалении индикатора удаляются и линии границ

2.3.6704
	* полностью убран режим работы через vlib2.dll
	* исправлено: при отключенных модах, но включенной максимальной, максимальная не рисовалась
	* +MP - показ максимальной моды по умолчанию отключен
	* исправлено: +VL - при отключенных модах, но включенных уровнях, уровни не рисовались

2.2.6294
	* режим работы без vlib2.dll
	* убраны лишние методы поиска мод
	* параметр Smooth переименован в ModeStep
	* код из +mpvl.mqh перенесен в основные файлы (упрощение установки и распространения)

2.1
	* исправлено: ошибка в расчетах
	* убраны лишние методы расчета (скрытый параметр TickMethod)
	* исправлено: автоопределение масштаба Smooth при работе на пятизнаке
	* добавлены опции в скрипте +FindVL

2.0
	* существенно увеличена скорость работы
	* оптимизирован набор параметров

1-18 (1.1-1.18)
	* тестовые версии, различающиеся по функционалу и параметрам

*/

/*

Copyright (c) FXcoder. All rights reserved.

Разрешается повторное распространение и использование как в виде исходного кода, так и в двоичной форме, с изменениями
или без, при соблюдении следующих условий:

    * При повторном распространении исходного кода должно оставаться указанное выше уведомление об авторском праве,
      этот список условий и последующий отказ от гарантий.

    * При повторном распространении двоичного кода должна сохраняться указанная выше информация об авторском праве, этот
      список условий и последующий отказ от гарантий в документации и/или в других материалах, поставляемых при
      распространении.

    * Ни название FXcoder, ни имена ее сотрудников не могут быть использованы в качестве поддержки или продвижения
      продуктов, основанных на этом ПО без предварительного письменного разрешения.

Эта программа предоставлена владельцами авторских прав и/или другими сторонами «как она есть» без какого-либо вида
гарантий, выраженных явно или подразумеваемых, включая, но не ограничиваясь ими, подразумеваемые гарантии коммерческой
ценности и пригодности для конкретной цели. Ни в коем случае ни один владелец авторских прав и ни одно другое лицо,
которое может изменять и/или повторно распространять программу, как было сказано выше, не несёт ответственности, включая
любые общие, случайные, специальные или последовавшие убытки, вследствие использования или невозможности использования
программы (включая, но не ограничиваясь потерей данных, или данными, ставшими неправильными, или потерями принесенными
из-за вас или третьих лиц, или отказом программы работать совместно с другими программами), даже если такой владелец или
другое лицо были извещены о возможности таких убытков.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
following conditions are met:

    * Redistributions of source code must retain the above copyright notice, this list of conditions and the following
      disclaimer.

    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
      following disclaimer in the documentation and/or other materials provided with the distribution.

    * Neither the name of the FXcoder nor the names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

This software is provided by the copyright holders and contributors "as is" and any express or implied warranties,
including, but not limited to, the implied warranties of merchantability and fitness for a particular purpose are
disclaimed. In no event shall the copyright holder or contributors be liable for any direct, indirect, incidental,
special, exemplary, or consequential damages (including, but not limited to, procurement of substitute goods or
services; loss of use, data, or profits; or business interruption) however caused and on any theory of liability,
whether in contract, strict liability, or tort (including negligence or otherwise) arising in any way out of the use of
this software, even if advised of the possibility of such damage.

*/

// 2016-04-18 18:51:02 UTC. MQLMake 1.42. © FXcoder