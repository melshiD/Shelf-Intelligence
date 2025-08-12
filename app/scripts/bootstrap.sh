#!/usr/bin/env bash
set -euo pipefail

# Run within /app
if [ ! -f artisan ]; then
  composer create-project laravel/laravel:^11.0 .
fi

# Dependencies
composer require laravel/breeze:^2.2 predis/predis guzzlehttp/guzzle league/flysystem-aws-s3-v3:^3.0 aws/aws-sdk-php:^3.0 --no-interaction --no-ansi

# Breeze install (Blade)
if [ ! -d resources/views/auth ]; then
  php artisan breeze:install blade --no-interaction
fi

# Ensure queue connection default to redis in .env.example
if ! grep -q '^QUEUE_CONNECTION=' .env.example; then
  echo 'QUEUE_CONNECTION=redis' >> .env.example
else
  sed -i 's/^QUEUE_CONNECTION=.*/QUEUE_CONNECTION=redis/' .env.example
fi

# Add example env keys
add_key() {
  local key="$1"
  grep -q "^${key}=" .env.example || echo "${key}=" >> .env.example
}
add_key DATABASE_URL
add_key REDIS_URL
add_key FILESYSTEM_DISK
sed -i 's/^FILESYSTEM_DISK=.*/FILESYSTEM_DISK=s3/' .env.example || true
add_key AWS_ACCESS_KEY_ID
add_key AWS_SECRET_ACCESS_KEY
add_key AWS_DEFAULT_REGION
add_key AWS_BUCKET
add_key AWS_ENDPOINT
add_key AWS_URL
add_key TMDB_API_KEY
add_key OMDB_API_KEY
add_key OPENAI_API_KEY
add_key CV_ANALYZER_URL

# Filesystem config already supports endpoint/URL by default in Laravel 11

# Routes: healthz, photos upload/show/json, watchlists stub
if ! grep -q "Route::get('/healthz'" routes/web.php; then
  cat >> routes/web.php <<'PHP'

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\PhotoController;
use App\Http\Controllers\WatchlistController;

Route::get('/healthz', function () {
    return response()->json(['ok' => true]);
});

Route::middleware(['auth'])->group(function () {
    Route::get('/photos', [PhotoController::class, 'index'])->name('photos.index');
    Route::post('/photos', [PhotoController::class, 'store'])->name('photos.store');
});

Route::get('/photos/{photo}', [PhotoController::class, 'show'])->name('photos.show');
Route::get('/photos/{photo}/json', [PhotoController::class, 'showJson'])->name('photos.show.json');

Route::middleware(['auth'])->group(function () {
    Route::resource('lists', WatchlistController::class)->only(['index','create','store','edit','update','destroy']);
});
PHP
fi

# Controllers
mkdir -p app/Http/Controllers
cat > app/Http/Controllers/PhotoController.php <<'PHP'
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use App\Models\Photo;
use App\Models\Item;
use App\Jobs\AnalyzePhoto;

class PhotoController extends Controller
{
    public function index()
    {
        $photos = Photo::query()->latest()->limit(20)->get();
        return view('photos.index', compact('photos'));
    }

    public function store(Request $request)
    {
        $request->validate([
            'photo' => 'required|image|max:10000',
        ]);
        $userId = optional(Auth::user())->id;
        $file = $request->file('photo');
        $filename = Str::uuid()->toString() . '.' . $file->getClientOriginalExtension();
        $path = Storage::disk('s3')->putFileAs('originals', $file, $filename);
        $img = @getimagesize($file->getRealPath());
        $width = $img[0] ?? null;
        $height = $img[1] ?? null;

        $photo = Photo::create([
            'user_id' => $userId,
            'original_url' => $path,
            'width' => $width,
            'height' => $height,
            'status' => 'queued',
        ]);

        AnalyzePhoto::dispatch($photo->id);

        return redirect()->route('photos.show', ['photo' => $photo->id]);
    }

    public function show(Photo $photo)
    {
        return view('photos.show', compact('photo'));
    }

    public function showJson(Photo $photo)
    {
        $photo->load('items');
        return response()->json([
            'photo' => $photo,
            'items' => $photo->items->map(function (Item $item) {
                return [
                    'id' => $item->id,
                    'polygon' => $item->polygon,
                    'bbox' => $item->bbox,
                    'angle' => $item->angle,
                    'crop_url' => $item->crop_url,
                    'ocr_raw' => $item->ocr_raw,
                    'ocr_conf' => $item->ocr_conf,
                    'normalized_title' => $item->normalized_title,
                ];
            }),
        ]);
    }
}
PHP

cat > app/Http/Controllers/WatchlistController.php <<'PHP'
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

class WatchlistController extends Controller
{
    public function index() { return view('lists.index'); }
    public function create() { return view('lists.create'); }
    public function store(Request $r) { return redirect()->route('lists.index'); }
    public function edit($id) { return view('lists.edit', ['id'=>$id]); }
    public function update(Request $r, $id) { return redirect()->route('lists.index'); }
    public function destroy($id) { return redirect()->route('lists.index'); }
}
PHP

# Views
mkdir -p resources/views/photos
cat > resources/views/photos/index.blade.php <<'BLADE'
@extends('layouts.app')
@section('content')
<div class="container mx-auto p-6">
  <h1 class="text-2xl font-bold mb-4">Upload Photo</h1>
  <form method="post" enctype="multipart/form-data" action="{{ route('photos.store') }}">
    @csrf
    <input type="file" name="photo" class="border p-2" />
    <button type="submit" class="ml-2 px-4 py-2 bg-blue-600 text-white">Upload</button>
  </form>
  <div class="mt-6">
    <h2 class="font-semibold mb-2">Recent Photos</h2>
    <ul>
      @foreach($photos as $p)
        <li><a class="text-blue-600 underline" href="{{ route('photos.show', $p->id) }}">Photo #{{ $p->id }}</a> - {{ $p->status }}</li>
      @endforeach
    </ul>
  </div>
</div>
@endsection
BLADE

cat > resources/views/photos/show.blade.php <<'BLADE'
@extends('layouts.app')
@section('content')
<div class="container mx-auto p-6" x-data="photoPage()" x-init="init()">
  <h1 class="text-2xl font-bold mb-4">Photo #{{ $photo->id }}</h1>
  <div class="mb-2">Status: <span x-text="data?.photo?.status || '{{ $photo->status }}'"></span></div>
  <div class="mb-2"><label><input type="checkbox" x-model="highlight"> Highlight watchlist matches</label></div>
  <div class="grid grid-cols-1 gap-4">
    <canvas id="overlay" class="border"></canvas>
  </div>
</div>
<script src="https://unpkg.com/alpinejs@3.x.x/dist/cdn.min.js" defer></script>
<script>
function photoPage() {
  return {
    data: null,
    highlight: false,
    async init() {
      const url = "{{ route('photos.show.json', $photo->id) }}";
      const poll = async () => {
        try {
          const res = await fetch(url, { headers: { 'Accept': 'application/json' }});
          if (!res.ok) throw new Error('fetch failed');
          this.data = await res.json();
          this.draw();
          const st = this.data.photo.status;
          if (st && (st === 'queued' || st === 'processing')) {
            setTimeout(poll, 2000);
          }
        } catch (e) { setTimeout(poll, 3000); }
      };
      poll();
    },
    draw() {
      const canvas = document.getElementById('overlay');
      const ctx = canvas.getContext('2d');
      const w = this.data?.photo?.width || 800;
      const h = this.data?.photo?.height || 600;
      canvas.width = w; canvas.height = h;
      ctx.clearRect(0,0,w,h);
      const items = this.data?.items || [];
      items.forEach(it => {
        const poly = it.polygon || [];
        if (poly.length >= 3) {
          ctx.beginPath();
          ctx.moveTo(poly[0][0], poly[0][1]);
          for (let i=1;i<poly.length;i++) ctx.lineTo(poly[i][0], poly[i][1]);
          ctx.closePath();
          ctx.fillStyle = 'rgba(0, 128, 255, 0.2)';
          ctx.fill();
          ctx.strokeStyle = 'rgba(0, 128, 255, 0.9)';
          ctx.lineWidth = 2; ctx.stroke();
          const label = (it.normalized_title || it.ocr_raw || 'item');
          ctx.fillStyle = '#003';
          ctx.fillRect(poly[0][0], poly[0][1]-18, ctx.measureText(label).width + 10, 18);
          ctx.fillStyle = '#fff';
          ctx.fillText(label, poly[0][0]+5, poly[0][1]-5);
        }
      });
    }
  }
}
</script>
@endsection
BLADE

# Models
mkdir -p app/Models
cat > app/Models/Photo.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

class Photo extends Model
{
    protected $fillable = ['user_id','original_url','width','height','status','error_message'];
    protected $casts = [];
    public function items(): HasMany { return $this->hasMany(Item::class); }
}
PHP

cat > app/Models/Item.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class Item extends Model
{
    protected $fillable = ['photo_id','polygon','bbox','angle','crop_url','ocr_raw','ocr_conf','normalized_title'];
    protected $casts = [ 'polygon' => 'array', 'bbox' => 'array' ];
    public function photo(): BelongsTo { return $this->belongsTo(Photo::class); }
}
PHP

cat > app/Models/Title.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class Title extends Model
{
    protected $fillable = ['canonical_title','year','tmdb_id','imdb_id','release_date','mpaa_rating','runtime_min','synopsis','imdb_url','acclaim'];
    protected $casts = [ 'acclaim' => 'array' ];
}
PHP

cat > app/Models/TitleItem.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class TitleItem extends Model
{
    protected $fillable = ['item_id','title_id','match_score'];
}
PHP

cat > app/Models/Person.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class Person extends Model
{
    protected $fillable = ['name','tmdb_id','imdb_id'];
}
PHP

cat > app/Models/Credit.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class Credit extends Model
{
    protected $fillable = ['title_id','person_id','role','character','ord'];
}
PHP

cat > app/Models/UserList.php <<'PHP'
<?php
namespace App\Models;
use Illuminate\Database\Eloquent\Model;

class UserList extends Model
{
    protected $table = 'lists';
    protected $fillable = ['user_id','name','type'];
}
PHP

# Services
mkdir -p app/Services
cat > app/Services/CvAnalyzer.php <<'PHP'
<?php
namespace App\Services;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;
use App\Models\Photo;

class CvAnalyzer
{
    public function healthz(): bool
    {
        $base = rtrim(env('CV_ANALYZER_URL', ''), '/');
        if ($base === '') return false;
        try { $r = Http::timeout(5)->get($base.'/healthz'); return $r->ok() && $r->json('ok')===true; } catch (\Throwable) { return false; }
    }

    public function analyzePhoto(Photo $photo, int $maxItems = 12): array
    {
        $base = rtrim(env('CV_ANALYZER_URL', ''), '/');
        if ($base === '') return [];
        // Generate a temporary URL for the analyzer
        $url = null;
        try { $url = Storage::disk('s3')->temporaryUrl($photo->original_url, now()->addMinutes(20)); } catch (\Throwable) { $url = null; }
        if (!$url) return [];
        try {
            $payload = ['image_url' => $url, 'max_items' => $maxItems];
            $r = Http::timeout(60)->post($base.'/analyze', $payload);
            if ($r->failed()) return [];
            return $r->json();
        } catch (\Throwable) { return []; }
    }
}
PHP

cat > app/Services/Tmdb.php <<'PHP'
<?php
namespace App\Services;
use Illuminate\Support\Facades\Http;

class Tmdb
{
    private function key(): ?string { return env('TMDB_API_KEY'); }

    public function search(string $query): array
    {
        $k = $this->key(); if (!$k) return [];
        $r = Http::timeout(10)->get('https://api.themoviedb.org/3/search/movie', ['api_key'=>$k,'query'=>$query]);
        return $r->ok() ? ($r->json('results') ?: []) : [];
    }

    public function details(int $tmdbId): array
    {
        $k = $this->key(); if (!$k) return [];
        $r = Http::timeout(10)->get("https://api.themoviedb.org/3/movie/{$tmdbId}", ['api_key'=>$k,'append_to_response'=>'credits']);
        return $r->ok() ? ($r->json() ?: []) : [];
    }
}
PHP

cat > app/Services/Omdb.php <<'PHP'
<?php
namespace App\Services;
use Illuminate\Support\Facades\Http;

class Omdb
{
    private function key(): ?string { return env('OMDB_API_KEY'); }

    public function byImdb(string $imdbId): array
    {
        $k = $this->key(); if (!$k) return [];
        $r = Http::timeout(10)->get('https://www.omdbapi.com/', ['apikey'=>$k,'i'=>$imdbId]);
        return $r->ok() ? ($r->json() ?: []) : [];
    }
}
PHP

cat > app/Services/TitleMatcher.php <<'PHP'
<?php
namespace App\Services;

class TitleMatcher
{
    // Simple PHP fallback matcher; replace with pg_trgm similarity in queries as needed
    public function score(string $a, string $b): float
    {
        $a = mb_strtolower(trim($a));
        $b = mb_strtolower(trim($b));
        similar_text($a, $b, $pct);
        return (float)$pct; // 0..100
    }
}
PHP

# Jobs
mkdir -p app/Jobs
cat > app/Jobs/AnalyzePhoto.php <<'PHP'
<?php
namespace App\Jobs;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\DB;
use App\Models\Photo;
use App\Models\Item;
use App\Services\CvAnalyzer;

class AnalyzePhoto implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public function __construct(public int $photoId) {}

    public function handle(CvAnalyzer $cv): void
    {
        $photo = Photo::find($this->photoId);
        if (!$photo) return;
        $photo->update(['status' => 'processing']);
        try {
            $result = $cv->analyzePhoto($photo, 12);
            $items = $result['items'] ?? [];
            DB::transaction(function () use ($photo, $items) {
                foreach ($items as $it) {
                    Item::create([
                        'photo_id' => $photo->id,
                        'polygon' => $it['polygon'] ?? null,
                        'bbox' => $it['bbox'] ?? null,
                        'angle' => $it['angle_deg'] ?? 0,
                        'crop_url' => $it['crop_url'] ?? null,
                        'ocr_raw' => $it['ocr']['raw'] ?? null,
                        'ocr_conf' => $it['ocr']['conf'] ?? null,
                        'normalized_title' => null,
                    ]);
                }
            });
            $photo->update(['status' => 'done']);
        } catch (\Throwable $e) {
            Log::error('AnalyzePhoto failed: '.$e->getMessage());
            $photo->update(['status' => 'failed', 'error_message' => $e->getMessage()]);
        }
    }
}
PHP

cat > app/Jobs/EnrichTitle.php <<'PHP'
<?php
namespace App\Jobs;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;

class EnrichTitle implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;
    public function __construct(public int $titleId) {}
    public function handle(): void { /* TODO: fetch TMDb/OMDb and persist */ }
}
PHP

cat > app/Jobs/WriteViewingBlurb.php <<'PHP'
<?php
namespace App\Jobs;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;

class WriteViewingBlurb implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;
    public function __construct(public int $titleId) {}
    public function handle(): void { /* TODO: call OpenAI and store blurb */ }
}
PHP

# Migrations
make_migration() {
  local name="$1"; shift
  php artisan make:migration "$name" "$@" >/dev/null 2>&1 || true
}

# photos table
if ! ls database/migrations/*_create_photos_table.php >/dev/null 2>&1; then
  make_migration create_photos_table --create=photos
  file=$(ls -1 database/migrations/*_create_photos_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('photos', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->nullable()->index();
            $table->string('original_url');
            $table->integer('width')->nullable();
            $table->integer('height')->nullable();
            $table->string('status')->default('queued');
            $table->text('error_message')->nullable();
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('photos'); }
};
PHP
fi

# items table
if ! ls database/migrations/*_create_items_table.php >/dev/null 2>&1; then
  make_migration create_items_table --create=items
  file=$(ls -1 database/migrations/*_create_items_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('items', function (Blueprint $table) {
            $table->id();
            $table->foreignId('photo_id')->index();
            $table->json('polygon')->nullable();
            $table->json('bbox')->nullable();
            $table->integer('angle')->default(0);
            $table->string('crop_url')->nullable();
            $table->text('ocr_raw')->nullable();
            $table->float('ocr_conf')->nullable();
            $table->string('normalized_title')->nullable();
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('items'); }
};
PHP
fi

# titles table
if ! ls database/migrations/*_create_titles_table.php >/dev/null 2>&1; then
  make_migration create_titles_table --create=titles
  file=$(ls -1 database/migrations/*_create_titles_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\DB;

return new class extends Migration {
    public function up(): void {
        Schema::create('titles', function (Blueprint $table) {
            $table->id();
            $table->string('canonical_title')->index();
            $table->integer('year')->nullable();
            $table->integer('tmdb_id')->nullable()->index();
            $table->string('imdb_id')->nullable()->index();
            $table->date('release_date')->nullable();
            $table->string('mpaa_rating')->nullable();
            $table->integer('runtime_min')->nullable();
            $table->text('synopsis')->nullable();
            $table->string('imdb_url')->nullable();
            $table->json('acclaim')->nullable();
            $table->timestamps();
        });
        try { DB::statement('CREATE EXTENSION IF NOT EXISTS pg_trgm'); } catch (\Throwable $e) {}
        try { DB::statement('CREATE INDEX IF NOT EXISTS titles_canonical_title_trgm ON titles USING gin (canonical_title gin_trgm_ops)'); } catch (\Throwable $e) {}
    }
    public function down(): void { Schema::dropIfExists('titles'); }
};
PHP
fi

# title_items table
if ! ls database/migrations/*_create_title_items_table.php >/dev/null 2>&1; then
  make_migration create_title_items_table --create=title_items
  file=$(ls -1 database/migrations/*_create_title_items_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('title_items', function (Blueprint $table) {
            $table->id();
            $table->foreignId('item_id')->index();
            $table->foreignId('title_id')->index();
            $table->float('match_score')->nullable();
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('title_items'); }
};
PHP
fi

# people table
if ! ls database/migrations/*_create_people_table.php >/dev/null 2>&1; then
  make_migration create_people_table --create=people
  file=$(ls -1 database/migrations/*_create_people_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('people', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->integer('tmdb_id')->nullable()->index();
            $table->string('imdb_id')->nullable()->index();
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('people'); }
};
PHP
fi

# credits table
if ! ls database/migrations/*_create_credits_table.php >/dev/null 2>&1; then
  make_migration create_credits_table --create=credits
  file=$(ls -1 database/migrations/*_create_credits_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('credits', function (Blueprint $table) {
            $table->id();
            $table->foreignId('title_id')->index();
            $table->foreignId('person_id')->index();
            $table->enum('role', ['actor','director','writer','producer'])->index();
            $table->string('character')->nullable();
            $table->integer('ord')->nullable();
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('credits'); }
};
PHP
fi

# lists table
if ! ls database/migrations/*_create_lists_table.php >/dev/null 2>&1; then
  make_migration create_lists_table --create=lists
  file=$(ls -1 database/migrations/*_create_lists_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('lists', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->index();
            $table->string('name');
            $table->enum('type', ['actors','titles'])->index();
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('lists'); }
};
PHP
fi

# pivot tables
if ! ls database/migrations/*_create_list_people_table.php >/dev/null 2>&1; then
  make_migration create_list_people_table --create=list_people
  file=$(ls -1 database/migrations/*_create_list_people_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('list_people', function (Blueprint $table) {
            $table->foreignId('list_id')->index();
            $table->foreignId('person_id')->index();
        });
    }
    public function down(): void { Schema::dropIfExists('list_people'); }
};
PHP
fi

if ! ls database/migrations/*_create_list_titles_table.php >/dev/null 2>&1; then
  make_migration create_list_titles_table --create=list_titles
  file=$(ls -1 database/migrations/*_create_list_titles_table.php | tail -n1)
  cat > "$file" <<'PHP'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('list_titles', function (Blueprint $table) {
            $table->foreignId('list_id')->index();
            $table->foreignId('title_id')->index();
        });
    }
    public function down(): void { Schema::dropIfExists('list_titles'); }
};
PHP
fi

# Build assets
if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --no-fund || npm install
    npm run build || true
  fi
fi

# Generate app key if .env exists
if [ -f .env ]; then
  php artisan key:generate --force || true
fi