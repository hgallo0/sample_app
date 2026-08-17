INSERT INTO advisors (name, email) VALUES
  ('Jordan Reyes', 'jordan.reyes@savvy.example');

INSERT INTO prospects (advisor_id, first_name, last_name, email, phone, stage, estimated_value, service_fee, notes) VALUES
  (1, 'Alice', 'Nguyen', 'alice.nguyen@example.com', '555-0101', 'lead', 50000, NULL, 'Referral from existing client.'),
  (1, 'Ben', 'Carter', 'ben.carter@example.com', '555-0102', 'contacted', 120000, NULL, 'Left voicemail, following up next week.'),
  (1, 'Carla', 'Diaz', 'carla.diaz@example.com', '555-0103', 'meeting_scheduled', 250000, NULL, 'Intro call booked for Thursday.'),
  (1, 'David', 'Emmerich', 'david.emmerich@example.com', '555-0104', 'proposal_sent', 400000, 0.5, 'Sent retirement planning proposal.'),
  (1, 'Elena', 'Frost', 'elena.frost@example.com', '555-0105', 'negotiation', 300000, 0.5, 'Negotiating fee structure.'),
  (1, 'Frank', 'Grady', 'frank.grady@example.com', '555-0106', 'client', 500000, 0.2, 'Signed on as a client last month.'),
  (1, 'Grace', 'Huang', 'grace.huang@example.com', '555-0107', 'lost', 80000, NULL, 'Went with a competitor.'),
  (1, 'Henry', 'Osei', 'henry.osei@example.com', '555-0201', 'lead', 90000, NULL, 'Inbound from webinar signup.'),
  (1, 'Isla', 'Petrova', 'isla.petrova@example.com', '555-0202', 'contacted', 150000, NULL, 'Responded to intro email, scheduling call.'),
  (1, 'Jamal', 'Quinn', 'jamal.quinn@example.com', '555-0203', 'meeting_scheduled', 220000, NULL, 'Discovery call set for next Tuesday.'),
  (1, 'Karen', 'Ruiz', 'karen.ruiz@example.com', '555-0204', 'proposal_sent', 310000, 0.5, 'Reviewing retirement rollover proposal.'),
  (1, 'Leo', 'Santos', 'leo.santos@example.com', '555-0205', 'negotiation', 275000, 0.5, 'Comparing fee structure with competitor.'),
  (1, 'Maya', 'Thompson', 'maya.thompson@example.com', '555-0206', 'client', 600000, 0.2, 'Onboarded last quarter, quarterly review scheduled.'),
  (1, 'Noah', 'Underwood', 'noah.underwood@example.com', '555-0207', 'lost', 60000, NULL, 'Decided to self-manage investments.'),
  (1, 'Olivia', 'Vance', 'olivia.vance@example.com', '555-0208', 'lead', 130000, NULL, 'Referral from Frank Grady.'),
  (1, 'Priya', 'Walsh', 'priya.walsh@example.com', NULL, 'contacted', 175000, NULL, 'Left voicemail, awaiting callback.'),
  (1, 'Quinn', 'Xu', 'quinn.xu@example.com', '555-0210', 'client', 450000, 0.2, 'Signed retainer agreement this month.');
