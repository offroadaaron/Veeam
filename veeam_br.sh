#!/bin/bash
#Linux Veeam commandline backup and restore script

function list_mounts_and_optionally_unmount() {
  echo "🔍 Checking for existing active mounts..."
  mapfile -t active_mounts < <(veeamconfig session list | grep 'Mount' | grep 'Running')

  if [ ${#active_mounts[@]} -gt 0 ]; then
    echo "⚠️  Active mount session(s) found:"
    for i in "${!active_mounts[@]}"; do
      session_line="${active_mounts[$i]}"
      session_id=$(echo "$session_line" | grep -o '{[^}]*}' | tr -d '{}')
      session_time=$(echo "$session_line" | awk '{print $(NF-2), $(NF-1)}')
      echo "  $((i+1))) $session_id - $session_time"
    done

    read -rp "❓ Do you want to unmount these sessions? [y/N]: " unmount_choice
    if [[ "$unmount_choice" =~ ^[Yy]$ ]]; then
      for session_line in "${active_mounts[@]}"; do
        session_id=$(echo "$session_line" | grep -o '{[^}]*}' | tr -d '{}')
        echo "🛑 Unmounting session: $session_id"
        veeamconfig session stop --id "$session_id"
      done
      echo "✅ All active mount sessions have been unmounted."
    fi

    read -rp "🔁 Do you want to mount another restore point? [y/N]: " remount_choice
    if [[ ! "$remount_choice" =~ ^[Yy]$ ]]; then
      echo "👋 Exiting."
      exit 0
    fi
  else
    echo "✅ No active mount sessions found."
  fi
}

function run_backup() {
  echo "🔍 Fetching available backup jobs..."
  mapfile -t job_info < <(veeamconfig job list | awk 'NR>1 {printf "%-30s %s\n", $1, $2}')

  if [ ${#job_info[@]} -eq 0 ]; then
      echo "❌ No backup jobs found!"
      exit 1
  fi

  echo "✅ Available backup jobs:"
  for i in "${!job_info[@]}"; do
      name=$(echo "${job_info[$i]}" | awk '{print $1}')
      id=$(echo "${job_info[$i]}" | awk '{print $2}')
      printf " %2d) %-30s %s\n" $((i+1)) "$name" "$id"
  done

  read -p "Enter the number of the backup job to run: " selection
  if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#job_info[@]}" ]; then
      echo "❌ Invalid selection."
      exit 1
  fi

  selected_line="${job_info[$((selection-1))]}"
  job_name=$(echo "$selected_line" | awk '{print $1}')
  job_id=$(echo "$selected_line" | awk '{print $2}')

  echo "🚀 Starting backup job: $job_name"
  output=$(veeamconfig job start --name "$job_name" 2>&1)

  log_dir=$(echo "$output" | grep -oP '/var/log/veeam/Backup/[^/]+/Session_[^/]+_\{[^}]+\}')
  log_file="$log_dir/Job.log"

  echo "📄 Monitoring logs at: $log_file"
  while [ ! -f "$log_file" ]; do sleep 1; done

  spin='-\|/'
  i=0
  progress_done=0

  tail -n0 -F "$log_file" | while read -r line; do
    if [[ "$progress_done" -eq 0 && "$line" =~ Session\ progress:\ ([0-9]{1,3})% ]]; then
        percent="${BASH_REMATCH[1]}"
        hashes=$(printf '#%.0s' $(seq 1 $((percent / 5)) ))
        spaces=$(printf ' %.0s' $(seq 1 $((20 - percent / 5)) ))
        printf "\r📦 Progress: [%-20s] %3d%% %s" "$hashes$spaces" "$percent" "${spin:i++%4:1}"

        if [[ "$percent" -ge 100 ]]; then
            progress_done=1
            echo -e "\n🎯 Backup complete. Finalizing..."
        fi
    elif [[ "$progress_done" -eq 1 ]]; then
        printf "\r🕐 Finalizing backup... %s" "${spin:i++%4:1}"
    fi

    if [[ "$line" =~ JOB\ STATUS:\ (.+)\. ]]; then
        job_status="${BASH_REMATCH[1]}"
        echo ""
        if [[ "$job_status" == "SUCCESS" ]]; then
            echo "✅ Backup SUCCEEDED!"
        elif [[ "$job_status" == "FAILED" ]]; then
            echo "❌ Backup FAILED!"
        else
            echo "⚠️ Unknown job status: $job_status"
        fi
        pkill -P $$ tail
        break
    fi
  done

  echo -e "\n🔍 Retrieving Backup ID for: $job_name"
  backup_id=$(veeamconfig backup list | awk -v name="$job_name" '
      BEGIN { IGNORECASE=1 }
      $0 ~ name {
          match($0, /\{[0-9a-fA-F-]+\}/)
          if (RSTART > 0) {
              uuid = substr($0, RSTART+1, RLENGTH-2)
              print uuid
              exit
          }
      }')

  if [[ ! "$backup_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      echo "❌ Failed to retrieve valid UUID for job '$job_name'."
      exit 1
  fi

  echo "📦 Backup ID: $backup_id"
  echo "📚 Listing restore points for this backup..."
  veeamconfig backup info --id "$backup_id" | column -t
}

function run_restore() {
  list_mounts_and_optionally_unmount

  echo "🔍 Fetching available backup jobs..."
  mapfile -t jobs < <(veeamconfig backup list | awk 'NR>1 {print $0}')

  if [ ${#jobs[@]} -eq 0 ]; then
    echo "❌ No backup jobs found."
    exit 1
  fi

  echo "✅ Available backups:"
  for i in "${!jobs[@]}"; do
    job_line="${jobs[$i]}"
    job_name=$(echo "$job_line" | awk '{for(i=1;i<=NF-3;i++) printf $i " "; print ""}' | sed 's/ *$//')
    echo "  $((i+1))) $job_name"
  done

  read -rp "Enter the number of the backup to inspect: " job_index
  job_line="${jobs[$((job_index-1))]}"
  backup_id=$(echo "$job_line" | grep -o '{[^}]*}' | tr -d '{}')

  if [[ -z "$backup_id" ]]; then
    echo "❌ Failed to retrieve valid Backup ID."
    exit 1
  fi

  echo "📂 Selected backup ID: $backup_id"
  echo "📚 Listing restore points..."

  mapfile -t restore_points < <(veeamconfig backup info --id "$backup_id" | awk 'NR>1 {print $0}')

  if [ ${#restore_points[@]} -eq 0 ]; then
    echo "❌ No restore points found."
    exit 1
  fi

  for i in "${!restore_points[@]}"; do
    line="${restore_points[$i]}"
    job_name=$(echo "$line" | awk '{for(i=1;i<=NF-5;i++) printf $i " "; print ""}' | sed 's/ *$//')
    date=$(echo "$line" | awk '{print $(NF-2), $(NF-1)}')
    echo "  $((i+1))) $job_name - $date"
  done

  read -rp "Enter the number of the restore point to mount: " rp_index
  rp_line="${restore_points[$((rp_index-1))]}"
  restore_point_id=$(echo "$rp_line" | grep -o '{[^}]*}' | tr -d '{}')

  read -rp "📁 Enter mount directory [default: /mnt/backup]: " mount_dir
  mount_dir=${mount_dir:-/mnt/backup}

  echo "🧩 Mounting restore point..."
  veeamconfig point mount --id "$restore_point_id" --mountdir "$mount_dir"
}

# === Main Menu ===
clear
echo "🔄 What would you like to do?"
echo "1) Backup"
echo "2) Restore"
echo "3) Exit"
read -rp "#? " choice

case "$choice" in
  1) run_backup ;;
  2) run_restore ;;
  3) echo "👋 Exiting." && exit 0 ;;
  *) echo "❌ Invalid choice." && exit 1 ;;
esac
