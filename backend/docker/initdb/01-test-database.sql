-- Separate database for the integration test suite so a test run never
-- truncates development data.
create database cribwire_test owner cribwire;
