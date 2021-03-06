###############################################################################
# OVERVIEW:
# Code to create a cleaned person table from the combined 
# King County Housing Authority and Seattle Housing Authority data sets
# Aim is to have a single row per contiguous time in a house per person
#
# STEPS:
# 01 - Process raw KCHA data and load to SQL database
# 02 - Process raw SHA data and load to SQL database
# 03 - Bring in individual PHA datasets and combine into a single file ### (THIS CODE) ###
# 04 - Deduplicate data and tidy up via matching process
# 05 - Recode race and other demographics
# 06 - Clean up addresses
# 06a - Geocode addresses
# 07 - Consolidate data rows
# 08 - Add in final data elements and set up analyses
# 09 - Join with Medicaid eligibility data
# 10 - Set up joint housing/Medicaid analyses
#
# Alastair Matheson (PHSKC-APDE)
# alastair.matheson@kingcounty.gov
# 2016-05-13, split into separate files 2017-10
# 
###############################################################################

#### Set up global parameter and call in libraries ####
library(housing) # contains many useful functions for cleaning
library(odbc) # Used to connect to SQL server
library(data.table) # Used to read in csv files more efficiently
library(tidyverse) # Used to manipulate data
library(RJSONIO)
library(RCurl)

script <- RCurl::getURL("https://raw.githubusercontent.com/jmhernan/Housing/uw_test/processing/metadata/set_data_env.r")
eval(parse(text = script))

METADATA = RJSONIO::fromJSON("//home/ubuntu/data/metadata/metadata.json")

set_data_envr(METADATA,"combined")

options(max.print = 400, tibble.print_max = 50, scipen = 999)

if(sql == TRUE) {
  
  db.apde51 <- dbConnect(odbc(), "PH_APDEStore51")
  #### Bring in data ####
  # This takes ~60 seconds
  system.time(sha <- DBI::dbReadTable(db.apde51, "sha_combined"))

  # This takes ~35 seconds
  system.time(kcha_long <- DBI::dbReadTable(db.apde51, "kcha_reshaped"))

}

#### Fix up variable formats ####
# Vars mtw_admit_date & move_in_date missing in UW files
sha <- date_ymd_f(sha, act_date, admit_date, dob, reexam_date)

sha <- sha %>% mutate(bdrm_voucher = as.numeric(bdrm_voucher),
                      unit_zip = as.numeric(unit_zip))

kcha_long <- date_ymd_f(kcha_long, act_date, admit_date, dob, hh_dob)


#### Make variable to track where data came from ####
sha <- mutate(sha, agency_new = "SHA")
kcha_long <- mutate(kcha_long, agency_new = "KCHA")


#### Append data ####
pha <- bind_rows(kcha_long, sha)


#### Clean up data ####
### Lots of variables have white space
pha <- trim_f(pha, relcode, unit_add, unit_apt, unit_apt2, 
              unit_city, unit_state, contains("name"), 
              prog_type, vouch_type, property_name, 
              property_type, portfolio, cost_pha)


### Fix up inconsistent capitalization in key variables
# Change names to be consistently upper case
pha <- pha %>% mutate_at(vars(contains("name"), contains("unit"), 
                              prog_type, vouch_type, property_name, 
                              property_type, portfolio, cost_pha), 
                         funs(toupper))


### Relative code
pha <- pha %>%
  mutate(relcode = ifelse(relcode == "NULL" | is.na(relcode) | relcode == "", 
                          "", relcode))

### Social security numbers
pha <- pha %>%
  # Some SSNs are HUD/PHA-generated IDs so make two fields
  # (note that conversion of legitimate SSN to numeric strips out 
  # leading zeros and removes rows with characters)
  # Remove dashes first
  mutate_at(vars(ssn, hh_ssn), funs(str_replace_all(., "-", ""))) %>%
  mutate(ssn_c = ifelse(str_detect(ssn, "[:alpha:]"), ssn, ""),
         hh_ssn_c = ifelse(str_detect(hh_ssn, "[:alpha:]"), hh_ssn, "")) %>%
  mutate_at(vars(ssn, hh_ssn), funs(new = round(as.numeric(.), digits = 0)))

# ID junk SSNs and IDs
pha <- junk_ssn_num(pha, ssn_new)
pha <- junk_ssn_char(pha, ssn_c)

### Billed agency (just fix up KCHA and other common ones)
pha <- pha %>%
  mutate(cost_pha = ifelse(cost_pha %in% c("WAOO2", "WA02 ", " WA02", "W002"),
                           "WA002", cost_pha),
         cost_pha = ifelse(cost_pha == " WA03", "WA003", cost_pha),
         cost_pha = ifelse(cost_pha == "NULL" | is.na(cost_pha), "", cost_pha))

### Dates
# Strip out dob components for matching
pha <- pha %>%
  mutate(dob_y = as.numeric(lubridate::year(dob)), 
         dob_mth = as.numeric(lubridate::month(dob)),
         dob_d = as.numeric(lubridate::day(dob)))


# Find most common DOB by SSN (doesn't work for SSN = NA or 0)
# Need to figure out how to ID most common or most recent last name for 
# SSNs like 0 or NA
pha <- pha %>%
  group_by(ssn_new, ssn_c, dob) %>%
  mutate(dob_cnt = ifelse(ssn_new_junk == 0 | ssn_c_junk == 0, n(), NA)) %>%
  ungroup()


### Names overall
# Strip out multiple spaces in the middle of last names, periods,
# inconsistent apostrophes, extraneous commas, and other general fixes
pha <- pha %>%
  mutate_at(vars(contains("name")), funs(str_replace(., "[:space:]{2,}|, ", " "))) %>%
  mutate_at(vars(contains("name")), funs(str_replace(., "`", "'"))) %>%
  mutate_at(vars(contains("name")), funs(str_replace(., "_", "-"))) %>%
  mutate_at(vars(contains("name")), funs(str_replace(., "NULL|\\.|\"|\\\\", ""))) %>%
  mutate_at(vars(contains("name")), funs(ifelse(is.na(.), "", .)))


### First name
# Clean up where middle initial seems to be in first name field
# NOTE: There are many rows with a middle initial in the fname field AND 
# the mname field (and the initials are not always the same)
# Need to talk with PHAs to determine best approach
pha <- pha %>% mutate(
  fname_new = ifelse(
    str_detect(str_sub(fname, -2, -1), "[:space:][A-Z]"), str_sub(fname, 1, -3), fname),
  mname_new = 
    ifelse(str_detect(str_sub(fname, -2, -1), "[:space:][A-Z]") & 
             is.na(mname), str_sub(fname, -1), 
           ifelse(str_detect(str_sub(fname, -2, -1), "[:space:][A-Z]") &
                    !is.na(mname), 
                  paste(str_sub(fname, -1), mname, sep = " "), mname)))

### Last name suffix
# Need to look for suffixes in last name if wanting to merge with SHA data

suffix3 <- c(" JR", " SR"," II", " IV")
suffix4 <- c(" III", " LLL", " 2ND", " 111", " JR.")

pha <- pha %>%
  # Suffixes in last names
  mutate(
    lnamesuf_new = ifelse(str_detect(str_sub(lname, -3, -1), paste(suffix3, collapse="|")),
                          str_sub(lname, -2, -1), ""),
    lname_new = ifelse(str_detect(str_sub(lname, -3, -1), paste(suffix3, collapse="|")), 
                       str_sub(lname, 1, -4), lname),
    lnamesuf_new = ifelse(str_detect(str_sub(lname, -4, -1), paste(suffix4, collapse = "|")),
                          str_sub(lname, -3, -1), lnamesuf_new),
    lname_new = ifelse(str_detect(str_sub(lname, -4, -1), paste(suffix4, collapse = "|")),
                       str_sub(lname, 1, -5), lname_new),
    
    
    # Suffixes in first names
    lnamesuf_new = ifelse(str_detect(str_sub(fname_new, -3, -1), 
                                     paste(suffix3, collapse="|")),
                          str_sub(fname_new, -2, -1), lnamesuf_new),
    fname_new = ifelse(str_detect(str_sub(fname_new, -3, -1), paste(suffix3, collapse="|")),
                       str_sub(fname_new, 1, -4), fname_new),
    lnamesuf_new = ifelse(str_detect(str_sub(fname_new, -4, -1), paste(suffix4, collapse="|")),
                          str_sub(fname_new, -3, -1), lnamesuf_new),
    fname_new = ifelse(str_detect(str_sub(fname_new, -4, -1), paste(suffix4, collapse="|")),
                       str_sub(fname_new, 1, -5), fname_new),
    
    # Remove any punctuation or NAs
    lnamesuf_new = str_replace_all(lnamesuf_new, pattern = "[:punct:]|[:blank:]", replacement = ""),
    lnamesuf_new = ifelse(is.na(lnamesuf_new), "", lnamesuf_new)
  )

#### Set up variables for matching ####
### Sort records
pha <- arrange(pha, hh_ssn_new, hh_ssn_c, ssn_new, ssn_c, act_date)

### Make trimmed version of names
pha <- pha %>%
  mutate(
    # Trim puncutation
    lname_trim = str_replace_all(lname_new, "[:punct:]|[:digit:]|[:blank:]|`", ""),
    fname_trim = str_replace_all(fname_new, pattern = "[:punct:]|[:digit:]|[:blank:]|`", replacement = ""),
    # Make soundex versions of names for matching/grouping
    lname_phon = phonics::soundex(lname_trim),
    fname_phon = phonics::soundex(fname_trim),
    # Make truncated first and last names for matching/grouping (alternative to soundex)
    lname3 = substr(lname_trim, 1, 3),
    fname3 = substr(fname_trim, 1, 3)
  )


### Count which first names appear most often (doesn't work for SSN = NA or 0)
# Need to figure out how to ID most common or most recent last name for SSNs like 0 or NA
pha <- pha %>%
  group_by(ssn_new, ssn_c, fname_new) %>%
  mutate(fname_new_cnt = ifelse(ssn_new_junk == 0 | ssn_c_junk == 0, n(), NA)) %>%
  ungroup()

### Count which non-blank middle names appear most often (doesn't work for SSN = NA or 0)
# Need to figure out how to ID most common or most recent last name for SSNs like 0 or NA
pha_middle <- pha %>%
  filter(mname_new != "" & (ssn_new_junk == 0 | ssn_c_junk == 0)) %>%
  group_by(ssn_new, ssn_c, mname_new) %>%
  summarise(mname_new_cnt = n()) %>%
  ungroup()
pha <- left_join(pha, pha_middle, by = c("ssn_new", "ssn_c", "mname_new"))
rm(pha_middle)

### Last name
# Find the most recent surname used (doesn't work for SSN = NA or 0)
# NB. Some most recent surnames are blank so use one before that
# Need to figure out how to ID most common or most recent last name for SSNs like 0 or NA
pha_last <- pha %>%
  filter(lname_new != "" & (ssn_new_junk == 0 | ssn_c_junk == 0)) %>%
  arrange(ssn_new, ssn_c, desc(act_date)) %>%
  group_by(ssn_new, ssn_c) %>%
  mutate(lname_rec = lname_new[[1]]) %>%
  ungroup() %>%
  distinct(ssn_new, ssn_c, lname_rec)
pha <- left_join(pha, pha_last, by = c("ssn_new", "ssn_c"))
rm(pha_last)


### Count which non-blank last name suffixes appear most often (doesn't work for SSN = NA or 0)
# Need to figure out how to ID most common or most recent last name for SSNs like 0 or NA
pha_suffix <- pha %>%
  filter(lnamesuf_new != "" & (ssn_new_junk == 0 | ssn_c_junk == 0)) %>%
  group_by(ssn_new, ssn_c, lnamesuf_new) %>%
  summarise(lnamesuf_new_cnt = n()) %>%
  ungroup()
pha <- left_join(pha, pha_suffix, by = c("ssn_new", "ssn_c", "lnamesuf_new"))
rm(pha_suffix)


### Gender
# Count the number of genders recorded for an individual (doesn't work for SSN = NA or 0)
# Need to figure out how to ID most common or most recent last name for SSNs like 0 or NA
pha <- pha %>%
  mutate(gender_new = as.numeric(car::recode(gender, c("'F' = 1; 'female' = 1; 'Female' = 1; 
                                                       'M' = 2; 'male  ' = 2; 'Male  ' = 2; 
                                                       'NULL' = NA; else = NA")))) %>%
  group_by(ssn_new, ssn_c, gender_new) %>%
  mutate(gender_new_cnt = ifelse(ssn_new_junk == 0 | ssn_c_junk == 0, n(), NA)) %>%
  ungroup()


#### Save point ####
saveRDS(pha, file = paste0(housing_path, pha_fn))


#### Clean up ####
rm(kcha_long)
rm(sha)
rm(suffix3)
rm(suffix4)
gc()
