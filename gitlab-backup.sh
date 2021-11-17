#!/bin/bash

# Script for performing periodic daily, weekly and monthly GitLab backups

export BACKUP_DIR=
export BACKUP_MANAGED_DIR=
export BACKUP_KEEP_DAYS=7
export BACKUP_KEEP_WEEKS=4
export BACKUP_KEEP_MONTHS=6

KEEP_DAYS=${BACKUP_KEEP_DAYS}
KEEP_WEEKS=`expr $(((${BACKUP_KEEP_WEEKS} * 7) + 1))`
KEEP_MONTHS=`expr $(((${BACKUP_KEEP_MONTHS} * 31) + 1))`

#Initialize dirs
mkdir -p "${BACKUP_DIR}${BACKUP_MANAGED_DIR}/daily/" "${BACKUP_DIR}${BACKUP_MANAGED_DIR}/weekly/" "${BACKUP_DIR}${BACKUP_MANAGED_DIR}/monthly/"

#Initialize filename vers
DFILE="${BACKUP_DIR}${BACKUP_MANAGED_DIR}/daily/backup-`date +%Y%m%d-%H%M%S`.gitlab.tar"
WFILE="${BACKUP_DIR}${BACKUP_MANAGED_DIR}/weekly/backup-`date +%G%V`.gitlab.tar"
MFILE="${BACKUP_DIR}${BACKUP_MANAGED_DIR}/monthly/backup-`date +%Y%m`.gitlab.tar"

# https://docs.gitlab.com/omnibus/settings/backups.html
backup(){
  gitlab-backup create > /tmp/gitlab-backup-data.out && \
  gitlab-ctl backup-etc /u01/backups/ > /tmp/gitlab-backup-config.out
 
  local etc_backup=$(cat /tmp/gitlab-backup-config.out |tail | grep "complete" | cut -d ':' -f 2 | tr -d ' ')
  local data_backup=$(cat /tmp/gitlab-backup-data.out | grep "Creating backup archive" | cut -d ':' -f 2 | tr -d ' ' | sed s/...done//)
  tar -cvf ${DFILE} ${etc_backup} /u01/backups/${data_backup} /etc/gitlab/gitlab-secrets.json /etc/gitlab/gitlab.rb

  # Copy (hardlink) for each entry
  ln -vf "${DFILE}" "${WFILE}"
  ln -vf "${DFILE}" "${MFILE}"
  rm ${etc_backup} /u01/backups/${data_backup} /tmp/gitlab-backup-config.out /tmp/gitlab-backup-data.out
}

#restore https://docs.gitlab.com/ce/raketasks/backup_restore.html#restore-for-omnibus-gitlab-installations

cleanup(){
  #Clean old files
  echo "Cleaning older than ${KEEP_DAYS} days for gitlab backup..."
  find "${BACKUP_DIR}${BACKUP_MANAGED_DIR}/daily" -maxdepth 1 -mtime +${KEEP_DAYS} -name "backup-*.gitlab*" -exec rm -rf '{}' ';'
  find "${BACKUP_DIR}${BACKUP_MANAGED_DIR}/weekly" -maxdepth 1 -mtime +${KEEP_WEEKS} -name "backup-*.gitlab*" -exec rm -rf '{}' ';'
  find "${BACKUP_DIR}${BACKUP_MANAGED_DIR}/monthly" -maxdepth 1 -mtime +${KEEP_MONTHS} -name "backup-*.gitlab*" -exec rm -rf '{}' ';'
}

backup
cleanup
