-- Separate database for the integration test suite so a test run never
-- truncates development data.
create database kidscam_test owner kidscam;
