#!/bin/bash
### ============================================================
### MICRO_CONTENT — WINDOWS‑COMPATIBLE VERSION
### Generates short social-media style posts automatically
### ============================================================

# Folder to store generated posts
OUTPUT_DIR="$HOME/micro_posts"
mkdir -p "$OUTPUT_DIR"

# Number of posts to generate
POST_COUNT=10

# Hashtag and engagement examples
HASHTAGS=("#Motivation" "#DailyThought" "#TechTips" "#Inspiration" "#LifeHacks")
ENGAGE_LINES=("Like if you agree!" "Comment your thoughts!" "Share with a friend!" "Double-tap if this resonates!")

# Sample phrases / content snippets
CONTENT_SNIPPETS=(
    "Life is a journey, embrace every step."
    "Small habits lead to big results over time."
    "Creativity is intelligence having fun."
    "Consistency beats intensity when it comes to learning."
    "Focus on what you can control and let the rest go."
    "Even mistakes are progress if you learn from them."
    "Your mindset shapes your reality, choose wisely."
    "Challenge yourself every day, growth is waiting."
    "Celebrate small wins, they compound into success."
    "Curiosity is the spark that ignites innovation."
)

echo
echo "Generating $POST_COUNT posts in $OUTPUT_DIR..."
echo

for i in $(seq 1 $POST_COUNT); do
    # Pick a random content snippet
    CONTENT=${CONTENT_SNIPPETS[$RANDOM % ${#CONTENT_SNIPPETS[@]}]}
    
    # Pick a random hashtag
    HASHTAG=${HASHTAGS[$RANDOM % ${#HASHTAGS[@]}]}
    
    # Pick a random engagement line
    ENGAGE=${ENGAGE_LINES[$RANDOM % ${#ENGAGE_LINES[@]}]}
    
    # Generate timestamped filename
    FILENAME="$OUTPUT_DIR/post_$(date +%Y%m%d_%H%M%S)_$i.txt"
    
    # Write the post
    echo "$CONTENT" > "$FILENAME"
    echo >> "$FILENAME"
    echo "$HASHTAG" >> "$FILENAME"
    echo "$ENGAGE" >> "$FILENAME"
    
    echo "Created: $FILENAME"
done

echo
echo "All posts generated!"