-- to report 'cron like' sprocs that seem to be called more/less than normal

--select * from sprocs_evaluate_num_of_calls_last_hour ('2015-01-27',12)
--select * from sprocs_evaluate_num_of_calls_last_hour (NULL,NULL)

CREATE OR REPLACE FUNCTION monitor_data.sprocs_evaluate_num_of_calls_last_hour(
  IN  p_date			timestamp without time zone default NULL,
  IN  p_hour			integer default NULL,
  OUT host_name			text,
  OUT sproc_name		text,
  OUT curr_calls		bigint,
  OUT normal_calls		bigint
)
  RETURNS setof record AS
$$
DECLARE
  l_number_of_weeks	integer;
  l_alert_percent	integer;
  l_time_threshod	integer;
  l_prev_hour		integer;
  i			integer;
  l_date		timestamp without time zone;
  l_dates_array		timestamp without time zone array;

BEGIN

  l_alert_percent := 20;
  
  -- fix hour & date
  if (p_date IS NULL) then
     p_hour := extract (hour from current_time);
     if (p_hour = 0) then
        p_hour := 23;
        p_date := current_date - interval '1 day';
     else
        p_hour := p_hour -1;   
        p_date := current_date;
     end if;
  end if;

  if (p_hour IS NULL) then
     p_hour := extract (hour from current_time);
     if (p_hour = 0) then
        p_hour := 23;
        p_date := p_date - interval '1 day';
     else
        p_hour := p_hour -1;   
     end if;
  end if;

  if (p_hour = 0) then
     l_prev_hour := 1; -- go for next hour in this case
  else
     l_prev_hour := p_hour -1;
  end if;

  select mc_config_value::integer
    from monitoring_configuration
   where mc_config_name = 'total_time_same_days_hourly_past_samples'
    into l_number_of_weeks;

  select mc_config_value::integer
    from monitoring_configuration
   where mc_config_name = 'num_of_calls_same_days_hourly_percent'
    into l_alert_percent;

l_number_of_weeks := l_number_of_weeks +1;	-- for additional screaning - randum values less likely to presist
  i := 0;
  l_date := p_date;
  while i <= l_number_of_weeks loop

--raise notice '%',l_date;
    if (i > 0) then 
      l_dates_array := l_dates_array || l_date;
    end if;

    l_date := l_date - interval '7 day';
    i := i+1;
  end loop;


-- check three previous weeks, and last hour
  RETURN QUERY

	-- find the constant values
	select	
		h.host_name,
		--s1.ss_host_id,
		s1.ss_sproc_name, 
		min(coalesce(s9.ss_calls,0)),
		max(s1.ss_calls) 
	  from sprocs_summary s1 
	 inner join hosts h on 
		h.host_id = s1.ss_host_id
	  left join sprocs_summary s9 on 
		s9.ss_host_id = s1.ss_host_id and s9.ss_sproc_name = s1.ss_sproc_name and 
		s9.ss_hour = s1.ss_hour and s9.ss_date = p_date 
	  left join sprocs_summary s8 on -- previous day
		s8.ss_host_id = s1.ss_host_id and s8.ss_sproc_name = s1.ss_sproc_name and s8.ss_hour = s1.ss_hour and 
		s8.ss_date = p_date - interval '1 day' and s8.ss_is_suspect = s1.ss_is_suspect
	 where
		not s1.ss_is_suspect and 
		s1.ss_date = ANY (l_dates_array) and
		s1.ss_hour = p_hour and 
		s1.ss_sproc_name not in (' ', 'exec_generic') and
		not 1.0*coalesce(s9.ss_calls,0) between ((100.0 - l_alert_percent) / 100.0) *s1.ss_calls and ((100.0 + l_alert_percent) / 100.0) *s1.ss_calls and -- allow for 10% in either direction, for current 
		coalesce(s9.ss_calls,0) != coalesce(s8.ss_calls,0) and -- today's data differs from yesterday's data
		not coalesce(s9.ss_is_suspect,true) and -- just don't report suspect stuff, data is not missing, it is suspect...
		not exists (select 1 
			      from performance_ignore_list 
			     where (pil_host_id IS NULL or pil_host_id = s1.ss_host_id) AND 
			           (pil_object_name IS NULL or pil_object_name = s1.ss_sproc_name)
			    )
	 group by h.host_name, 
		s1.ss_sproc_name
--	having count(1) >= (l_number_of_weeks -1) and  -- allow one week of FOUR to be missing/different
	having count(1) = (l_number_of_weeks) and  -- DON'T allow one week of FOUR to be missing/different
		min(s1.ss_calls) = max(s1.ss_calls)	-- number of calls constant
	 order by 1,2;
/*
  RETURN QUERY
	select distinct 
		h.host_name,
		s1.ss_sproc_name, 
		coalesce(s9.ss_calls), 
		s1.ss_calls
	  from sprocs_summary s1 
         inner join sprocs_summary s2 on 
		s1.ss_host_id = s2.ss_host_id and s1.ss_sproc_name = s2.ss_sproc_name and s1.ss_hour=s2.ss_hour and 
		s1.ss_date = s2.ss_date + 7* interval '1 day' and s1.ss_is_suspect = s2.ss_is_suspect	and s1.ss_calls = s2.ss_calls
	  inner join sprocs_summary s3 on 
		s1.ss_host_id = s3.ss_host_id and s1.ss_sproc_name = s3.ss_sproc_name and s1.ss_hour = s3.ss_hour and 
		s1.ss_date = s3.ss_date + 14* interval '1 day' and s1.ss_is_suspect = s3.ss_is_suspect and s1.ss_calls = s3.ss_calls
	  inner join sprocs_summary s4 on 
		s1.ss_host_id = s4.ss_host_id and s1.ss_sproc_name = s4.ss_sproc_name and s1.ss_hour = s4.ss_hour and 
		s1.ss_date = s4.ss_date + 21* interval '1 day' and s1.ss_is_suspect = s4.ss_is_suspect and s1.ss_calls = s4.ss_calls
	  inner join hosts h on 
		h.host_id = s1.ss_host_id
	   left join sprocs_summary s9 on 
		s9.ss_host_id = s1.ss_host_id and s9.ss_sproc_name = s1.ss_sproc_name and 
		s9.ss_hour = s1.ss_hour and s9.ss_date = p_date and s9.ss_is_suspect = s1.ss_is_suspect
	   left join sprocs_summary s8 on -- previous day
		s8.ss_host_id = s1.ss_host_id and s8.ss_sproc_name = s1.ss_sproc_name and s8.ss_hour = s1.ss_hour and 
		s8.ss_date = p_date - interval '1 day' and s8.ss_is_suspect = s1.ss_is_suspect
	  where 
		not s1.ss_is_suspect and 
		s1.ss_date = p_date - 7*interval '1 day' and 
		s1.ss_hour = p_hour and 
		s1.ss_sproc_name not in (' ', 'exec_generic') and 
		not 1.0*coalesce(s9.ss_calls,0) between ((100.0 - l_alert_percent) / 100.0) *s1.ss_calls and ((100.0 + l_alert_percent) / 100.0) *s1.ss_calls and -- allow for 10% in either direction, for current 
		coalesce(s9.ss_calls,0) != coalesce(s8.ss_calls,0) and -- today's data differs from yesterday's data
		not exists (select 1 
			      from performance_ignore_list 
			     where (pil_host_id IS NULL or pil_host_id = s1.ss_host_id) AND 
			           (pil_object_name IS NULL or pil_object_name = s1.ss_sproc_name)
			    )
	  order by 1,2;
*/

END;
$$
  LANGUAGE 'plpgsql';

