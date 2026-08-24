-- Sohbetten olusan bir randevu silinmek istendiginde chat_sessions'taki
-- referans FK ihlali veriyordu. Randevu silinince baglanti bosa dussun.
alter table chat_sessions drop constraint chat_sessions_booked_appointment_id_fkey;
alter table chat_sessions add constraint chat_sessions_booked_appointment_id_fkey
  foreign key (booked_appointment_id) references appointments(id) on delete set null;
