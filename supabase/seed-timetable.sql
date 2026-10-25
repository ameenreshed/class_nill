-- Sections
insert into sections (section_id, name, strength) values
  ('CSE-4A', 'CSE 4th Year A', 60),
  ('CSE-4B', 'CSE 4th Year B', 60),
  ('ECE-3A', 'ECE 3rd Year A', 55)
on conflict (section_id) do nothing;

-- Sample timetable (Mon=1 … Sat=6)
insert into timetable (section_id, day_of_week, slot_id, room_id, course_code, course_name) values
  -- Monday
  ('CSE-4A', 1, 'P1', '27-107',  'CS401', 'Compiler Design'),
  ('CSE-4A', 1, 'P2', '27-107',  'CS402', 'Computer Networks'),
  ('CSE-4A', 1, 'P3', '27-108',  'CS403', 'DBMS Lab'),
  ('CSE-4B', 1, 'P1', '27-107A', 'CS401', 'Compiler Design'),
  ('CSE-4B', 1, 'P4', '27-208',  'CS404', 'Operating Systems'),
  ('ECE-3A', 1, 'P1', '27-207A', 'EC301', 'Signals & Systems'),

  -- Tuesday
  ('CSE-4A', 2, 'P1', '27-107',  'CS402', 'Computer Networks'),
  ('CSE-4A', 2, 'P5', '27-108',  'CS403', 'DBMS Lab'),
  ('CSE-4B', 2, 'P2', '27-107A', 'CS402', 'Computer Networks'),
  ('ECE-3A', 2, 'P3', '27-208',  'EC302', 'Digital Electronics'),

  -- Wednesday
  ('CSE-4A', 3, 'P1', '27-107',  'CS401', 'Compiler Design'),
  ('CSE-4A', 3, 'P3', '27-208',  'CS404', 'Operating Systems'),
  ('CSE-4B', 3, 'P2', '27-107A', 'CS401', 'Compiler Design'),
  ('ECE-3A', 3, 'P1', '27-207A', 'EC301', 'Signals & Systems'),

  -- Thursday
  ('CSE-4A', 4, 'P2', '27-107',  'CS402', 'Computer Networks'),
  ('CSE-4A', 4, 'P6', '27-108',  'CS403', 'DBMS Lab'),
  ('CSE-4B', 4, 'P1', '27-107A', 'CS401', 'Compiler Design'),
  ('ECE-3A', 4, 'P4', '27-208',  'EC302', 'Digital Electronics'),

  -- Friday
  ('CSE-4A', 5, 'P1', '27-107',  'CS401', 'Compiler Design'),
  ('CSE-4A', 5, 'P2', '27-107',  'CS404', 'Operating Systems'),
  ('CSE-4B', 5, 'P3', '27-107A', 'CS402', 'Computer Networks'),
  ('ECE-3A', 5, 'P1', '27-207A', 'EC301', 'Signals & Systems')
on conflict (section_id, day_of_week, slot_id) do nothing;

select 'Timetable seeded' as status, count(*) as rows from timetable;