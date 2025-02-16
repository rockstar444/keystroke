/*
  # Enhance keystroke pattern verification

  1. Changes
    - Add weighted scoring for different keystroke features
    - Improve pattern normalization
    - Add confidence scoring
    - Add detailed match analysis
    - Add adaptive thresholds based on historical data

  2. Security
    - Maintain existing RLS policies
    - Add input validation
*/

-- Create type for detailed match analysis
CREATE TYPE keystroke_match_details AS (
  dwell_time_match float,
  flight_time_match float,
  pattern_consistency float,
  overall_confidence float
);

-- Create function to normalize keystroke patterns
CREATE OR REPLACE FUNCTION normalize_keystroke_pattern(
  dwell_times float[],
  flight_times float[]
) RETURNS float[] 
LANGUAGE plpgsql
AS $$
DECLARE
  normalized float[];
  dwell_mean float;
  dwell_std float;
  flight_mean float;
  flight_std float;
BEGIN
  -- Calculate statistics for dwell times
  SELECT avg(d), stddev(d)
  INTO dwell_mean, dwell_std
  FROM unnest(dwell_times) d;

  -- Calculate statistics for flight times
  SELECT avg(f), stddev(f)
  INTO flight_mean, flight_std
  FROM unnest(flight_times) f;

  -- Normalize values using z-score normalization
  -- Handle edge case where standard deviation is 0
  normalized := array(
    SELECT 
      CASE 
        WHEN i % 2 = 0 AND dwell_std > 0 THEN (dwell_times[i/2+1] - dwell_mean) / dwell_std
        WHEN i % 2 = 1 AND flight_std > 0 THEN (flight_times[i/2+1] - flight_mean) / flight_std
        ELSE 0
      END
    FROM generate_series(0, array_length(dwell_times, 1) * 2 - 1) i
  );

  RETURN normalized;
END;
$$;

-- Create function to calculate adaptive threshold
CREATE OR REPLACE FUNCTION calculate_adaptive_threshold(
  user_id uuid,
  recent_attempts int DEFAULT 10
) RETURNS float
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  threshold float;
BEGIN
  -- Calculate adaptive threshold based on recent successful attempts
  SELECT avg(match_score) * 0.8 -- 80% of average successful match score
  INTO threshold
  FROM (
    SELECT (aa.metadata->>'match_score')::float as match_score
    FROM auth_attempts aa
    WHERE aa.user_id = calculate_adaptive_threshold.user_id
      AND aa.success = true
      AND aa.attempted_at > now() - interval '7 days'
    ORDER BY aa.attempted_at DESC
    LIMIT recent_attempts
  ) recent_scores;

  -- Fallback to default threshold if not enough data
  RETURN COALESCE(threshold, 0.7);
END;
$$;

-- Enhanced verify_keystroke_pattern function
CREATE OR REPLACE FUNCTION verify_keystroke_pattern(
  user_id uuid,
  session_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_pattern float[];
  historical_patterns float[][];
  match_score float;
  match_details keystroke_match_details;
  adaptive_threshold float;
  requesting_user uuid;
  current_dwell_times float[];
  current_flight_times float[];
BEGIN
  -- Get the authenticated user's ID
  requesting_user := auth.uid();
  
  -- Verify the user is only accessing their own data
  IF requesting_user IS NULL OR requesting_user != user_id THEN
    RAISE EXCEPTION 'Unauthorized access';
  END IF;

  -- Get adaptive threshold
  adaptive_threshold := calculate_adaptive_threshold(user_id);

  -- Get current session's keystroke data
  WITH current_keystrokes AS (
    SELECT 
      array_agg(dwell_time ORDER BY created_at) as dwell_times,
      array_agg(COALESCE(flight_time, 0) ORDER BY created_at) as flight_times
    FROM keystroke_data
    WHERE session_id = verify_keystroke_pattern.session_id
  )
  SELECT 
    dwell_times, flight_times 
  INTO current_dwell_times, current_flight_times
  FROM current_keystrokes;

  -- Normalize current pattern
  current_pattern := normalize_keystroke_pattern(
    current_dwell_times,
    current_flight_times
  );

  -- Get historical patterns from recent successful attempts
  WITH historical_sessions AS (
    SELECT DISTINCT ON (ks.id) 
      ks.id as session_id
    FROM keystroke_sessions ks
    INNER JOIN auth_attempts aa ON aa.user_id = ks.user_id
    WHERE ks.user_id = verify_keystroke_pattern.user_id
      AND ks.id != verify_keystroke_pattern.session_id
      AND aa.success = true
    ORDER BY ks.id, aa.attempted_at DESC
    LIMIT 5
  ),
  historical_keystrokes AS (
    SELECT 
      hs.session_id,
      normalize_keystroke_pattern(
        array_agg(kd.dwell_time ORDER BY kd.created_at),
        array_agg(COALESCE(kd.flight_time, 0) ORDER BY kd.created_at)
      ) as pattern
    FROM historical_sessions hs
    INNER JOIN keystroke_data kd ON kd.session_id = hs.session_id
    GROUP BY hs.session_id
  )
  SELECT array_agg(pattern)
  INTO historical_patterns
  FROM historical_keystrokes;

  -- Calculate detailed match analysis
  SELECT 
    avg(dwell_match)::float as dwell_time_match,
    avg(flight_match)::float as flight_time_match,
    stddev(total_match)::float as pattern_consistency,
    (avg(total_match) * (1 - COALESCE(stddev(total_match), 0)))::float as overall_confidence
  INTO match_details
  FROM (
    SELECT
      1.0 / (1.0 + sqrt(sum(power(c[1] - h[1], 2)) / array_length(current_pattern, 1))) as dwell_match,
      1.0 / (1.0 + sqrt(sum(power(c[2] - h[2], 2)) / array_length(current_pattern, 1))) as flight_match,
      1.0 / (1.0 + sqrt(sum(power(c[1] - h[1], 2) + power(c[2] - h[2], 2)) / (2 * array_length(current_pattern, 1)))) as total_match
    FROM unnest(current_pattern) WITH ORDINALITY AS c(value, idx)
    CROSS JOIN unnest(historical_patterns) AS historical_pattern
    JOIN unnest(historical_pattern) WITH ORDINALITY AS h(value, idx) ON c.idx = h.idx
    GROUP BY historical_pattern
  ) pattern_matches;

  -- Calculate final match score with weighted features
  match_score := (
    match_details.dwell_time_match * 0.4 +    -- 40% weight for dwell time
    match_details.flight_time_match * 0.4 +    -- 40% weight for flight time
    match_details.pattern_consistency * 0.2    -- 20% weight for consistency
  ) * match_details.overall_confidence;        -- Scale by confidence

  -- Return comprehensive match results
  RETURN json_build_object(
    'match_score', match_score,
    'threshold', adaptive_threshold,
    'details', json_build_object(
      'dwell_time_match', match_details.dwell_time_match,
      'flight_time_match', match_details.flight_time_match,
      'pattern_consistency', match_details.pattern_consistency,
      'overall_confidence', match_details.overall_confidence
    ),
    'recommendation', CASE 
      WHEN match_score >= adaptive_threshold THEN 'accept'
      WHEN match_score >= adaptive_threshold * 0.8 THEN 'challenge'
      ELSE 'reject'
    END
  );
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION normalize_keystroke_pattern(float[], float[]) TO authenticated;
GRANT EXECUTE ON FUNCTION calculate_adaptive_threshold(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION verify_keystroke_pattern(uuid, uuid) TO authenticated;

-- Add helpful comments
COMMENT ON FUNCTION normalize_keystroke_pattern IS 'Normalizes keystroke timing patterns using z-score normalization';
COMMENT ON FUNCTION calculate_adaptive_threshold IS 'Calculates adaptive verification threshold based on recent successful attempts';
COMMENT ON FUNCTION verify_keystroke_pattern IS 'Enhanced keystroke pattern verification with detailed analysis and adaptive thresholds';