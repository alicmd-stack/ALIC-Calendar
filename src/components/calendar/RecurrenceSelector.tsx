import React, { useState, useEffect } from 'react';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Input } from '@/components/ui/input';
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group';
import { Checkbox } from '@/components/ui/checkbox';

export interface RecurrenceConfig {
  frequency: 'none' | 'daily' | 'weekly' | 'monthly' | 'yearly';
  interval: number;
  daysOfWeek?: number[]; // 0 = Sunday, 1 = Monday, etc.
  dayOfMonth?: number;
  monthOfYear?: number;
  endType: 'never' | 'on' | 'after';
  endDate?: string;
  occurrences?: number;
}

interface RecurrenceSelectorProps {
  value: RecurrenceConfig;
  onChange: (config: RecurrenceConfig) => void;
  startDate?: string;
}

const DAYS_OF_WEEK = [
  { label: 'Sun', value: 0 },
  { label: 'Mon', value: 1 },
  { label: 'Tue', value: 2 },
  { label: 'Wed', value: 3 },
  { label: 'Thu', value: 4 },
  { label: 'Fri', value: 5 },
  { label: 'Sat', value: 6 },
];

const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];

export const RecurrenceSelector: React.FC<RecurrenceSelectorProps> = ({
  value,
  onChange,
  startDate,
}) => {
  const updateConfig = (updates: Partial<RecurrenceConfig>) => {
    onChange({ ...value, ...updates });
  };

  const toggleDayOfWeek = (day: number) => {
    const currentDays = value.daysOfWeek || [];
    const newDays = currentDays.includes(day)
      ? currentDays.filter(d => d !== day)
      : [...currentDays, day].sort((a, b) => a - b);
    updateConfig({ daysOfWeek: newDays });
  };

  // Set default days of week based on start date when switching to weekly
  useEffect(() => {
    if (value.frequency === 'weekly' && (!value.daysOfWeek || value.daysOfWeek.length === 0) && startDate) {
      const startDay = new Date(startDate).getDay();
      updateConfig({ daysOfWeek: [startDay] });
    }
  }, [value.frequency, startDate]);

  if (value.frequency === 'none') {
    return (
      <div className="space-y-4">
        <div>
          <Label htmlFor="recurrence">Recurrence</Label>
          <Select
            value={value.frequency}
            onValueChange={(freq) => updateConfig({
              frequency: freq as RecurrenceConfig['frequency'],
              interval: 1,
              endType: 'never'
            })}
          >
            <SelectTrigger id="recurrence">
              <SelectValue placeholder="Does not repeat" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Does not repeat</SelectItem>
              <SelectItem value="daily">Daily</SelectItem>
              <SelectItem value="weekly">Weekly</SelectItem>
              <SelectItem value="monthly">Monthly</SelectItem>
              <SelectItem value="yearly">Yearly</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-4 p-4 border rounded-lg bg-muted/50">
      {/* Frequency Selector */}
      <div>
        <Label htmlFor="recurrence">Recurrence</Label>
        <Select
          value={value.frequency}
          onValueChange={(freq) => {
            const newFreq = freq as RecurrenceConfig['frequency'];
            updateConfig({
              frequency: newFreq,
              interval: 1,
              daysOfWeek: newFreq === 'weekly' && startDate ? [new Date(startDate).getDay()] : undefined,
              dayOfMonth: newFreq === 'monthly' && startDate ? new Date(startDate).getDate() : undefined,
              monthOfYear: newFreq === 'yearly' && startDate ? new Date(startDate).getMonth() + 1 : undefined,
            });
          }}
        >
          <SelectTrigger id="recurrence">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="none">Does not repeat</SelectItem>
            <SelectItem value="daily">Daily</SelectItem>
            <SelectItem value="weekly">Weekly</SelectItem>
            <SelectItem value="monthly">Monthly</SelectItem>
            <SelectItem value="yearly">Yearly</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {/* Interval */}
      <div className="flex items-center gap-2">
        <Label htmlFor="interval" className="whitespace-nowrap">Repeat every</Label>
        <Input
          id="interval"
          type="number"
          min="1"
          max="99"
          value={value.interval}
          onChange={(e) => updateConfig({ interval: Math.max(1, parseInt(e.target.value) || 1) })}
          className="w-20"
        />
        <span className="text-sm text-muted-foreground">
          {value.frequency === 'daily' && (value.interval === 1 ? 'day' : 'days')}
          {value.frequency === 'weekly' && (value.interval === 1 ? 'week' : 'weeks')}
          {value.frequency === 'monthly' && (value.interval === 1 ? 'month' : 'months')}
          {value.frequency === 'yearly' && (value.interval === 1 ? 'year' : 'years')}
        </span>
      </div>

      {/* Weekly: Days of Week Selector */}
      {value.frequency === 'weekly' && (
        <div>
          <Label className="mb-2 block">Repeat on</Label>
          <div className="flex gap-2">
            {DAYS_OF_WEEK.map((day) => (
              <button
                key={day.value}
                type="button"
                onClick={() => toggleDayOfWeek(day.value)}
                className={`
                  w-10 h-10 rounded-full flex items-center justify-center text-sm font-medium
                  transition-colors
                  ${(value.daysOfWeek || []).includes(day.value)
                    ? 'bg-primary text-primary-foreground'
                    : 'bg-muted hover:bg-muted/80'
                  }
                `}
              >
                {day.label}
              </button>
            ))}
          </div>
          {(!value.daysOfWeek || value.daysOfWeek.length === 0) && (
            <p className="text-sm text-destructive mt-1">Please select at least one day</p>
          )}
        </div>
      )}

      {/* Monthly: Day of Month */}
      {value.frequency === 'monthly' && (
        <div>
          <Label htmlFor="dayOfMonth">Repeat on day</Label>
          <Input
            id="dayOfMonth"
            type="number"
            min="1"
            max="31"
            value={value.dayOfMonth || 1}
            onChange={(e) => updateConfig({ dayOfMonth: Math.min(31, Math.max(1, parseInt(e.target.value) || 1)) })}
            className="w-24"
          />
          <p className="text-xs text-muted-foreground mt-1">
            Day of the month (1-31)
          </p>
        </div>
      )}

      {/* Yearly: Month Selection */}
      {value.frequency === 'yearly' && (
        <div className="space-y-2">
          <div>
            <Label htmlFor="monthOfYear">Repeat in</Label>
            <Select
              value={String(value.monthOfYear || 1)}
              onValueChange={(month) => updateConfig({ monthOfYear: parseInt(month) })}
            >
              <SelectTrigger id="monthOfYear">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {MONTHS.map((month, idx) => (
                  <SelectItem key={idx} value={String(idx + 1)}>
                    {month}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div>
            <Label htmlFor="yearDayOfMonth">On day</Label>
            <Input
              id="yearDayOfMonth"
              type="number"
              min="1"
              max="31"
              value={value.dayOfMonth || 1}
              onChange={(e) => updateConfig({ dayOfMonth: Math.min(31, Math.max(1, parseInt(e.target.value) || 1)) })}
              className="w-24"
            />
          </div>
        </div>
      )}

      {/* End Type */}
      <div className="space-y-3">
        <Label>Ends</Label>
        <RadioGroup
          value={value.endType}
          onValueChange={(endType) => updateConfig({ endType: endType as RecurrenceConfig['endType'] })}
        >
          <div className="flex items-center space-x-2">
            <RadioGroupItem value="never" id="never" />
            <Label htmlFor="never" className="font-normal cursor-pointer">Never</Label>
          </div>

          <div className="flex items-center space-x-2">
            <RadioGroupItem value="on" id="on" />
            <Label htmlFor="on" className="font-normal cursor-pointer">On</Label>
            <Input
              type="date"
              value={value.endDate || ''}
              onChange={(e) => updateConfig({ endDate: e.target.value, endType: 'on' })}
              onClick={() => updateConfig({ endType: 'on' })}
              min={startDate}
              className="ml-2 w-auto"
              disabled={value.endType !== 'on'}
            />
          </div>

          <div className="flex items-center space-x-2">
            <RadioGroupItem value="after" id="after" />
            <Label htmlFor="after" className="font-normal cursor-pointer">After</Label>
            <Input
              type="number"
              min="1"
              max="999"
              value={value.occurrences || 1}
              onChange={(e) => updateConfig({ occurrences: Math.max(1, parseInt(e.target.value) || 1), endType: 'after' })}
              onClick={() => updateConfig({ endType: 'after' })}
              className="ml-2 w-20"
              disabled={value.endType !== 'after'}
            />
            <span className="text-sm text-muted-foreground">occurrences</span>
          </div>
        </RadioGroup>
      </div>

      {/* Summary */}
      <div className="pt-2 border-t">
        <p className="text-sm text-muted-foreground">
          <strong>Summary:</strong> {getRecurrenceSummary(value)}
        </p>
      </div>
    </div>
  );
};

// Helper function to generate human-readable summary
function getRecurrenceSummary(config: RecurrenceConfig): string {
  if (config.frequency === 'none') return 'Does not repeat';

  let summary = `Repeats every ${config.interval > 1 ? config.interval + ' ' : ''}`;

  switch (config.frequency) {
    case 'daily':
      summary += config.interval === 1 ? 'day' : 'days';
      break;
    case 'weekly':
      summary += config.interval === 1 ? 'week' : 'weeks';
      if (config.daysOfWeek && config.daysOfWeek.length > 0) {
        const dayNames = config.daysOfWeek.map(d => DAYS_OF_WEEK[d].label).join(', ');
        summary += ` on ${dayNames}`;
      }
      break;
    case 'monthly':
      summary += config.interval === 1 ? 'month' : 'months';
      if (config.dayOfMonth) {
        summary += ` on day ${config.dayOfMonth}`;
      }
      break;
    case 'yearly':
      summary += config.interval === 1 ? 'year' : 'years';
      if (config.monthOfYear && config.dayOfMonth) {
        summary += ` on ${MONTHS[config.monthOfYear - 1]} ${config.dayOfMonth}`;
      }
      break;
  }

  if (config.endType === 'on' && config.endDate) {
    summary += `, until ${new Date(config.endDate).toLocaleDateString()}`;
  } else if (config.endType === 'after' && config.occurrences) {
    summary += `, ${config.occurrences} times`;
  }

  return summary;
}

// Helper function to convert RecurrenceConfig to RRULE string
export function recurrenceConfigToRRule(config: RecurrenceConfig, startDate: Date): string | null {
  if (config.frequency === 'none') return null;

  const parts: string[] = [];

  // Frequency
  parts.push(`FREQ=${config.frequency.toUpperCase()}`);

  // Interval
  if (config.interval > 1) {
    parts.push(`INTERVAL=${config.interval}`);
  }

  // Days of week (for weekly)
  if (config.frequency === 'weekly' && config.daysOfWeek && config.daysOfWeek.length > 0) {
    const dayMap = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
    const days = config.daysOfWeek.map(d => dayMap[d]).join(',');
    parts.push(`BYDAY=${days}`);
  }

  // Day of month (for monthly/yearly)
  if ((config.frequency === 'monthly' || config.frequency === 'yearly') && config.dayOfMonth) {
    parts.push(`BYMONTHDAY=${config.dayOfMonth}`);
  }

  // Month of year (for yearly)
  if (config.frequency === 'yearly' && config.monthOfYear) {
    parts.push(`BYMONTH=${config.monthOfYear}`);
  }

  // End condition
  if (config.endType === 'on' && config.endDate) {
    const endDate = new Date(config.endDate);
    endDate.setHours(23, 59, 59, 999);
    const until = endDate.toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
    parts.push(`UNTIL=${until}`);
  } else if (config.endType === 'after' && config.occurrences) {
    parts.push(`COUNT=${config.occurrences}`);
  }

  return parts.join(';');
}

// Helper function to parse RRULE string to RecurrenceConfig
export function rruleToRecurrenceConfig(rrule: string | null): RecurrenceConfig {
  if (!rrule) {
    return {
      frequency: 'none',
      interval: 1,
      endType: 'never',
    };
  }

  const config: RecurrenceConfig = {
    frequency: 'none',
    interval: 1,
    endType: 'never',
  };

  const parts = rrule.split(';');

  for (const part of parts) {
    const [key, value] = part.split('=');

    switch (key) {
      case 'FREQ':
        config.frequency = value.toLowerCase() as RecurrenceConfig['frequency'];
        break;
      case 'INTERVAL':
        config.interval = parseInt(value);
        break;
      case 'BYDAY':
        const dayMap: { [key: string]: number } = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };
        config.daysOfWeek = value.split(',').map(d => dayMap[d]).filter(d => d !== undefined);
        break;
      case 'BYMONTHDAY':
        config.dayOfMonth = parseInt(value);
        break;
      case 'BYMONTH':
        config.monthOfYear = parseInt(value);
        break;
      case 'UNTIL':
        config.endType = 'on';
        config.endDate = value.slice(0, 8).replace(/(\d{4})(\d{2})(\d{2})/, '$1-$2-$3');
        break;
      case 'COUNT':
        config.endType = 'after';
        config.occurrences = parseInt(value);
        break;
    }
  }

  return config;
}
