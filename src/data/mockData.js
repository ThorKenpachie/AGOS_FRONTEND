// Alert-level display config (label/color/description/action per bucket).
// The actual alert level itself always comes from the live model backend
// (or Supabase) -- this file only maps that value to how it's presented.
//
// Everything else that used to live in this file (generateWaterLevelData,
// generateRainfallData, HISTORICAL_FLOODS, WEATHER_FORECAST, DATA_SOURCES,
// FLOOD_ZONES, NOTIFICATION_LOG) was leftover fabricated placeholder data
// from before this app was wired to Supabase/the live model API, and was
// never imported anywhere. Removed rather than left to bit-rot -- one entry
// (DATA_SOURCES' "LSTM Flood Prediction Model ... local Flask backend")
// was actively wrong about the current architecture, which is exactly the
// kind of stale hardcoded content worth deleting instead of leaving as a
// misleading trap for the next person reading this file.

export const ALERT_LEVELS = {
  NORMAL: {
    label: 'Normal',
    color: '#22c55e',
    bg: '#dcfce7',
    border: '#16a34a',
    description: 'No significant flooding risk. Water levels within safe range.',
    action: 'No action required. Continue monitoring.',
    level: 0,
  },
  ADVISORY: {
    label: 'Advisory',
    color: '#eab308',
    bg: '#fef9c3',
    border: '#ca8a04',
    description: 'Elevated water levels. Minor flooding possible in low-lying areas.',
    action: 'Residents near waterways should be on alert.',
    level: 1,
  },
  WARNING: {
    label: 'Warning',
    color: '#f97316',
    bg: '#ffedd5',
    border: '#ea580c',
    description: 'Significant flooding expected.',
    action: 'Prepare evacuation. Secure valuables. Monitor updates.',
    level: 2,
  },
  CRITICAL: {
    label: 'Critical',
    color: '#ef4444',
    bg: '#fee2e2',
    border: '#dc2626',
    description: 'Severe flooding imminent. Immediate danger to life and property.',
    action: 'EVACUATE IMMEDIATELY. Proceed to designated evacuation centers.',
    level: 3,
  },
};
